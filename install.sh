#!/bin/sh
# Autopilot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/install.sh | sh -s -- --dry-run
#
# The manifest and the notarized dmg are served from that same public repo
# (axetechnologies/autopilot-dist); the dmg is a release asset. To install from
# somewhere else, point the script at any host serving an equivalent manifest:
#
#   AUTOPILOT_MANIFEST=https://example.com/latest.json ./install.sh
#
# POSIX sh on purpose — no bashisms, so it runs under sh, dash, and zsh.
#
# WHY A CHECKSUM IS MANDATORY HERE:
# The app is code-signed with a Developer ID AND, as of 2026-09-06, notarized —
# `spctl -a` on the .app returns "accepted, source=Notarized Developer ID". So a
# browser download now passes Gatekeeper too; this channel is no longer the only
# way in. curl still sets no com.apple.quarantine xattr, which means Gatekeeper
# is not consulted at all on this path.
#
# But that also means Gatekeeper never checks WHO signed the bundle. macOS still
# validates that the signature is internally consistent, so it will not run a
# bundle whose contents were altered under an intact signature — yet a tampered
# bundle that was simply re-signed (ad-hoc or with any other cert) launches fine
# once there is no quarantine flag.
#
# So the signature does not protect this channel against substitution in
# transit; the SHA-256 in the manifest is what does. No checksum, no install.
# Fail closed.

set -eu

MANIFEST_URL="${AUTOPILOT_MANIFEST:-https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/latest.json}"
APP_NAME="Autopilot.app"
DRY_RUN=0
DEST=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --dest=*)  DEST="${arg#--dest=}" ;;
    -h|--help)
      sed -n '2,12p' "$0" 2>/dev/null || echo "curl -fsSL https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/install.sh | sh"
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ── Platform gate ─────────────────────────────────────────────────────────────
# electron-builder only produces a mac dmg today. Say so plainly rather than
# failing halfway through with a confusing hdiutil error.
[ "$(uname -s)" = "Darwin" ] || die "Autopilot ships a macOS .dmg only (found $(uname -s)). No Linux/Windows build exists yet."

need curl
need shasum
need hdiutil
need plutil

ARCH="$(uname -m)"

# ── Resolve the manifest ──────────────────────────────────────────────────────
say "Fetching manifest: $MANIFEST_URL"
# curl exit 6 is a DNS failure. Report it as one rather than as "manifest not
# found", which sends people looking for a missing file instead.
MANIFEST="$(curl -fsSL "$MANIFEST_URL")" || {
  rc=$?
  if [ "$rc" -eq 6 ]; then
    echo "✗ Cannot resolve the host in $MANIFEST_URL." >&2
    echo "  Check DNS/network, or point this at a manifest you can reach:" >&2
    echo "    AUTOPILOT_MANIFEST=https://your-host/latest.json $0" >&2
    exit 1
  fi
  die "could not fetch manifest from $MANIFEST_URL (curl exit $rc)"
}

# Parse without jq — it is not on a stock macOS. plutil reads JSON natively.
mjson() {
  printf '%s' "$MANIFEST" | plutil -extract "$1" raw -o - - 2>/dev/null || true
}

VERSION="$(mjson version)"
DMG_URL="$(mjson dmg_url)"
SHA256="$(mjson sha256)"
DMG_ARCH="$(mjson arch)"

[ -n "$VERSION" ] || die "manifest has no 'version'"
[ -n "$DMG_URL" ] || die "manifest has no 'dmg_url'"
[ -n "$SHA256" ] || die "manifest has no 'sha256' — refusing to install an unverifiable unsigned binary"

case "$SHA256" in
  ????????????????????????????????????????????????????????????????) : ;;
  *) die "manifest sha256 is not 64 hex chars: '$SHA256'" ;;
esac

# electron-builder targets the host arch, so a build is single-arch. Refuse a
# mismatch rather than installing 119MB of an app that cannot launch. Manifests
# without an `arch` field are older ones — warn instead of guessing.
if [ -n "$DMG_ARCH" ] && [ "$DMG_ARCH" != "$ARCH" ]; then
  die "this build is for $DMG_ARCH, but this Mac is $ARCH.
No $ARCH build is published. Autopilot is built per-architecture, so the
$DMG_ARCH bundle will not launch here."
fi
if [ -z "$DMG_ARCH" ]; then
  say "note: manifest declares no arch; assuming it matches $ARCH"
fi

say "Autopilot $VERSION ($ARCH)"

# ── Destination ───────────────────────────────────────────────────────────────
# Prefer /Applications, fall back to ~/Applications when it is not writable,
# so the installer never needs sudo and never half-fails on a managed Mac.
if [ -z "$DEST" ]; then
  if [ -w /Applications ]; then DEST=/Applications
  else DEST="$HOME/Applications"; say "note: /Applications not writable — using $DEST"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "dry run — nothing will be written"
  say "  version : $VERSION"
  say "  dmg     : $DMG_URL"
  say "  sha256  : $SHA256"
  say "  dest    : $DEST/$APP_NAME"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-install.XXXXXX")"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

DMG="$TMP/autopilot.dmg"

# ── Download ──────────────────────────────────────────────────────────────────
say "Downloading (119MB or so, be patient)..."
curl -fL --progress-bar -o "$DMG" "$DMG_URL" || die "download failed: $DMG_URL"

# ── Verify — the only integrity check that exists ─────────────────────────────
say "Verifying SHA-256..."
GOT="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
  die "CHECKSUM MISMATCH — refusing to install.
  expected $SHA256
  got      $GOT
curl sets no quarantine flag, so macOS never checks who signed this bundle —
the checksum is the real integrity guarantee for this channel. A mismatch means a corrupted download or a tampered artifact.
Not installing."
fi
say "  ok — $GOT"

# ── Install ───────────────────────────────────────────────────────────────────
# Only now create the destination — a refused install should leave no trace.
mkdir -p "$DEST"
say "Mounting..."
# Mount at a path we choose rather than parsing hdiutil's output — the previous
# version interpolated $TMP into an awk regex, where its slashes made the
# pattern invalid.
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null 2>&1 \
  || die "could not mount $DMG"
[ -d "$MOUNT" ] || die "mounted $DMG but $MOUNT is not a directory"

SRC="$(find "$MOUNT" -maxdepth 1 -name '*.app' -print 2>/dev/null | head -1)"
[ -n "$SRC" ] || die "no .app found inside the dmg"

TARGET="$DEST/$APP_NAME"
if [ -e "$TARGET" ]; then
  say "Replacing existing install at $TARGET"
  rm -rf "$TARGET.old" 2>/dev/null || true
  mv "$TARGET" "$TARGET.old" || die "could not move aside $TARGET (is Autopilot running?)"
fi

say "Installing to $TARGET"
if cp -R "$SRC" "$TARGET"; then
  rm -rf "$TARGET.old" 2>/dev/null || true
else
  [ -e "$TARGET.old" ] && mv "$TARGET.old" "$TARGET" 2>/dev/null || true
  die "copy failed; previous install restored"
fi

# Strip any quarantine flag that did get set.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

say ""
say "Installed Autopilot $VERSION -> $TARGET"
say ""
say "  open -a '$TARGET'"
say ""
say "The MCP server and CLI are distributed separately, via pkg.axe.onl:"
say "  npm config set @memjar:registry https://pkg.axe.onl"
say "  npx @memjar/autopilot-mcp install-skills"
