# Autopilot — distribution

Public install channel for **Autopilot**. This repo holds only the installer, the
release manifest, and the built macOS disk images. The application source lives
in a private repository.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/install.sh | sh
```

Preview what it would do without writing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/axetechnologies/autopilot-dist/main/install.sh | sh -s -- --dry-run
```

Requires an Apple-silicon Mac. The installer refuses to run on anything else
rather than installing a bundle that cannot launch.

The build is Developer ID signed **and notarized**, so downloading the `.dmg`
from the [releases page](../../releases/latest) by hand works too.

### Why the installer verifies a checksum

`curl` sets no `com.apple.quarantine` flag, so Gatekeeper is never consulted on
this path — macOS never checks *who* signed the bundle. The SHA-256 in
`latest.json` is therefore the integrity guarantee for this channel, and
`install.sh` refuses to install without a match.

## MCP server and CLI

Distributed separately, from a private npm registry:

```sh
npm config set @memjar:registry https://pkg.axe.onl
npx @memjar/autopilot-mcp install-skills
```

Reads from that registry are anonymous — no token needed.

## Files

| file | purpose |
| --- | --- |
| `install.sh` | the installer the one-liner pipes to `sh` |
| `latest.json` | version, dmg url, sha256, arch, size |
| release assets | the notarized `.dmg` per version |
