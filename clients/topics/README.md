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
  (`topics-sdk.js`) and its types (`topics-sdk.d.ts`), the ready-made
  cards (`cards.js`: list, table, recurring, shopping, notes, schedule, all
  stored in one `items` table), the pixel helpers (`sprite.js`), and the
  pages:
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

## Connecting Gmail

Onboarding's "Connect a Gmail account" button (also in Settings → Gmail)
runs Veetbot's own `python -m gmail_mcp bootstrap --account-id <name>` from
the Veetbot folder. Each of the three Google consents shows the command's
data-use disclosure, and what the owner types is passed straight to the
command, so it still needs the exact word CONTINUE. Afterwards Topics:

1. adds the account to `~/.config/veetbot/gmail-accounts.json`, the
   ADR-0085 accounts manifest (owner-only, validated as Veetbot does);
2. points Veetbot's `.env` at it (`GMAIL_ACCOUNTS_FILE`,
   `AGENT_EMAIL_ENABLED=1`) and comments out the three legacy
   `GMAIL_*_CREDENTIAL_FILE` lines, keeping a `.env.topics-backup`;
3. restarts Veetbot through two LaunchAgents,
   `com.sabina.veetbot.api` (`serve_https_api.py`) and
   `com.sabina.veetbot.worker` (`agent worker`), logging to
   `~/Library/Logs/Veetbot/`. The first time, it asks before stopping
   Veetbot processes started from a terminal;
4. waits for the account to appear in `GET /v1/email/accounts`, then
   retries the onboarding scan.

The first account becomes the default and keeps the `gmail_read`,
`gmail_write` and `gmail_send` tool names. Credentials made by the legacy
single-account ceremony carry no account name, so they can't be reused in
the manifest: reconnect that mailbox under a name instead. The Veetbot
folder and the OAuth client file
(`~/.config/veetbot/client-secret.json` by default) are set in Settings.
