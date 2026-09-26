# Claude Permission Inspector

A small macOS app that lists the privacy permissions (TCC) and notification
settings granted to `Claude.app` (Claude desktop) and `claude.app` (Claude Code).
Each row has a button that opens the matching page in System Settings.

## Build

```bash
./build.sh
open "build/Claude Permission Inspector.app"
```

Requires macOS 14+ and the Xcode Command Line Tools.

## Full Disk Access

The TCC databases are protected, so the app needs Full Disk Access
(System Settings › Privacy & Security › Full Disk Access). Granting it to this
app avoids granting it to your terminal.

The build is ad-hoc signed, so each rebuild changes its signature: remove the
app from the Full Disk Access list and add it again after rebuilding.
