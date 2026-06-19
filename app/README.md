# Paste2SSH

Paste2SSH is a tiny macOS Dock and menu bar utility that uploads copied images or screenshots to an SSH host and copies the absolute remote path back to the clipboard.

## Build

```sh
./build.sh
```

The build creates:

- `Paste2SSH.app`
- `Paste2SSH.dmg`

The app targets macOS 14 or newer and is ad-hoc signed for v1. On first launch outside a notarized build, use right-click -> Open, or approve it in System Settings -> Privacy & Security.

## SSH prerequisite

Paste2SSH shells out to the system `ssh` and `scp`. Your target must already work from Terminal:

```sh
ssh your-host-alias
```

The app does not store passwords or keys. It relies on your existing `~/.ssh/config`, keys, ssh-agent, known hosts, and host aliases.

## Development

```sh
swift run
```

Notifications are skipped under `swift run`; test the full menu bar behavior from the assembled `.app`.
