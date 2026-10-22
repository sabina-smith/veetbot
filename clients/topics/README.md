# Topics for macOS (prototype)

A dashboard-first app on Veetbot: one board and one helper agent per area
of life. See `DESIGN-BRIEF.md` for what the product does and
`../../topics/ARCHITECTURE.md` for the design behind it.

## Layout

- `Topics/`: the SwiftUI app: the topic rail, and one web page per screen
  (a topic's board, Home, New topic), plus the helpers' connection to
  Veetbot through `VeetbotCore` from `../apple`. The design follows the
  "Topics redesign" MagicPath project.
- `TopicsKit/`: the model layer, tested with `swift test`: the shared
  schedule and its redaction rules, the per-topic workspace (files, git,
  SQLite), proposals, and parsing and applying the agent's changes.
- `Bundle/sdk/`: the design system (`topics-sdk.css`), the module runtime
  (`topics-sdk.js`) and its types (`topics-sdk.d.ts`), and the pages:
  `board.js` (masthead, Needs you, cards, ask bar, decision sheet),
  `home.js` and `newtopic.js`.
- `Bundle/templates/`: starting workspaces for Garden, Household, and
  `blank` (Work, Health and new topics, whose helper sketches the board).

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
accept `-snapshotDir <dir>` (PNG snapshots of the window, plus
`errors.log` for card errors), `-screen home|new|<topic id>` and
`-autoCheckIn YES`.
