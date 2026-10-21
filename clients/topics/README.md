# Topics for macOS (prototype)

A dashboard-first app on Veetbot: one board and one helper agent per area
of life. See `DESIGN-BRIEF.md` for what the product does and
`../../topics/ARCHITECTURE.md` for the design behind it.

## Layout

- `Topics/`: the SwiftUI app (board, module cards, the helper's sidebar,
  the Veetbot connection through `VeetbotCore` from `../apple`).
- `TopicsKit/`: the model layer, tested with `swift test`: the shared
  schedule and its redaction rules, the per-topic workspace (files, git,
  SQLite), proposals, and parsing and applying the agent's changes.
- `Bundle/sdk/`: the module runtime (`topics-sdk.js`, `.css`) and the types
  modules are written against (`topics-sdk.d.ts`).
- `Bundle/templates/garden/`: the Garden topic's starting workspace.

## Build and run

```sh
./build-install.sh            # build, install to ~/Applications/Topics.app, launch
(cd TopicsKit && swift test)  # model tests
```

Needs Xcode 27.1, Node.js 22.6 or newer (modules are TypeScript, built by
type stripping), and the local Veetbot API at `https://localhost:8443`.
Signing uses the Personal Team `43MF8FKV2C`, bundle `com.sabina.topics`.

Each topic's workspace is a git repository under
`~/Library/Application Support/Topics/workspaces/<topic>`. Debug builds
accept `-snapshotDir <dir>` (PNG snapshots of the window) and
`-autoCheckIn YES`.
