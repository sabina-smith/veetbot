# Topics: what the app does (design brief)

A plain description of the product's core, for redesigning the interface.
It describes what the app must let a person do, not how today's prototype
lays it out. The architecture behind it is in `topics/ARCHITECTURE.md`.

## The idea in one paragraph

Your life is split into **topics**: Garden, Household, Work, Health. Each
topic has its own **board** (a dashboard built from cards) and its own
**helper** (an AI agent with a name, like Fern for the Garden). The helper
works *on the board with you*: it fills in rows, researches things, adds
new cards when you start tracking something, and asks for your decision
only when one is needed. The one thing all topics share is **time**: what's
scheduled and what's due shows up across topics, as short labels only.

## Who it's for

Someone who has never thought about "agents". They should feel they have a
capable helper for each part of their life, not software to operate. The
interface never shows how the helper works inside (no files, notes,
prompts, databases, ids, status codes or "runs").

## The core objects

| Object | What it is to the person | Examples |
| --- | --- | --- |
| **Topic** | An area of life with its own board and helper. Can be **private** (sealed): nothing from it is visible anywhere else; its time shows only as "Busy". | Garden, Household, Work, Health (private) |
| **Helper** | The topic's agent. Has a name and a voice; always the same "person" when you come back. | Fern |
| **Board** | The topic's canvas of cards. Different for every topic, and it changes over time. | Garden: map, to-dos, tool shed, shopping |
| **Card** | One tool on the board: a list, a table, a picture, a tracker. The helper can create, change or remove cards. | Garden map, Tool shed |
| **Row / item** | A thing inside a card: a plant, a tool, a task, something to buy. Both you and the helper edit rows. | "Compost, 3 cu ft" |
| **Decision** (proposal) | The helper needs your call on a specific row: approve a purchase, pick between options, answer a question. Comes with the helper's options, prices, links and its recommendation. | "Compost: 2 options from $24" |
| **Time item** | Something with a date: a block of time, a task due, a reminder. Visible across topics as a short label. | "Garden: plant garlic, Sat" |
| **Person** | Someone you know, kept centrally; each topic has its own view of how to deal with them. *(Designed, not built yet.)* | Dana the landscaper |

## What the person does

These are the jobs the interface has to support, roughly in order of how
often they happen.

1. **See what needs me.** Across a topic (and later across all topics):
   decisions waiting, tasks due soon, and what the helper did since I last
   looked.
2. **Make a decision in place.** Open what the helper found, compare the
   options (price, where, link), pick one or decline, optionally add a note
   ("closer to me", "organic only"). The row updates immediately.
3. **Work with the board directly.** Add, edit and check off rows on any
   card, like a normal app. No helper involved.
4. **Hand something to the helper.** From a row ("find this", "ask Fern")
   or by typing a request ("I want to keep track of my seeds").
5. **See the helper working, and stop it.** Know when it's busy and on
   what; stop it if it was started by accident.
6. **Watch the board grow.** When the helper adds or changes a card, notice
   what changed, and undo it if I don't like it.
7. **Talk to the helper.** Ask questions or give preferences. Secondary to
   the board: the helper's answers should be short, with the details on
   the board.
8. **Switch topics and see time across them.** Move between topics; see
   one shared view of what's coming up ("Home"), where other topics appear
   only as labels and private ones only as "Busy".
9. **Create and shape topics.** New topic, name, icon, colour, private or
   not, what its helper should care about. A new topic starts with a short
   conversation and the helper proposes a first board.

## What the helper does (so the design can show it)

- **Looks in, does some work, leaves.** It isn't always running. It comes
  by when asked, when you hand it something, or after you make a decision.
  To you it is continuous: it remembers what it promised.
- **Fills in rows.** Research results go into the row itself: source,
  link, price, a short note.
- **Asks with a decision, not a chat message.** Anything that needs you
  becomes a decision attached to a row.
- **Reshapes the board.** Adds a card when you start tracking something
  new, tweaks a card that's awkward, fixes one that breaks. One change at a
  time, always undoable.
- **Never spends or sends without you.** Purchases and anything with
  real-world effects wait for your explicit approval. (Today it can't buy
  anything itself; an approved purchase becomes a one-click link.)
- **Learns your preferences** within the topic ("prefers named varieties",
  "repairs before replacing") and uses them in what it suggests.

## Moments and states to design

| Moment | What the person needs to see |
| --- | --- |
| Opening a topic | The board, with anything waiting on them visible without hunting. |
| Helper is working | That it's busy, roughly on what ("looking things up"), and a Stop. |
| Helper finished | What changed, ideally in place on the board (highlighted rows or cards), plus a one-line summary. |
| A decision is waiting | A clear marker on the row; one click opens the options; confirm or decline in place. |
| Helper researching a row | A light "Fern is looking" marker on that row. |
| Helper changed a card | The new or changed card is noticeable; undo is close by. |
| A card broke | A calm "this card couldn't load, Fern will fix it", never an error dump. |
| Empty topic / first visit | An invitation to tell the helper about this part of your life. |
| Private topic | Clearly marked as private; nothing leaks into Home or other topics. |
| Approval for a real-world action | An unmistakable "needs your OK" with exactly what will happen. |

## Garden, the worked example

- **Cards:** a map of the garden (beds and what's planted where, click a
  bed to see and edit its plants); a to-do list (tasks for you or for Fern,
  with due dates, "Ask Fern", "Put on schedule"); a tool shed (tools by
  kind with condition, "Replace" puts a worn tool on the shopping list); a
  shopping list (needed → researching → in cart → ordered → arrived, with
  where, link and price; "Fern, find it").
- **A typical loop:** you click "Fern, find it" on compost → the row shows
  "Fern is looking" → Fern researches → the row gets a source, link and
  price, plus a decision "2 options from $24" → you open it, pick one, add
  "closer to me" → the row moves to in cart with the link → Fern notes your
  preference for next time.
- **Growing the board:** you say "I want to keep track of my seeds" → Fern
  adds a Seeds card (and the data behind it) and tells you in one line.

## What's real today and what isn't

- **Real:** the helper (a real model, through Veetbot), its research, its
  edits to the board, new cards it writes, decisions, undo, stop, the
  Garden board and its data, the shared schedule rules (labels only,
  private topics as "Busy").
- **Not built yet:** other topics and topic creation, the Home view, people
  and their per-topic views, real purchasing through store accounts, the
  helper looking in on a timer, and running each topic's helper on its own
  cloud machine.

## Constraints that should shape the design

- **One app look.** Cards are built from a shared set of building blocks
  (lists, tables, forms, badges, charts, a drawing surface), so a card the
  helper writes looks native. The design system for those blocks is part
  of this redesign.
- **The board is the main surface; chat is secondary.**
- **Every helper change is undoable.** Changes to card layout and code can
  be undone; data changes (rows) currently can't.
- **Privacy is structural.** A private topic's details never appear outside
  it, including in notifications and Home.
- **The helper's work takes time** (tens of seconds to a few minutes), so
  the design should let you keep working on the board while it works.

## Open questions for the design

1. Where do decisions live: only on their rows, in a per-topic inbox, in a
   cross-topic inbox on Home, or all three?
2. How should "what the helper changed" show up: highlights on the board,
   a feed, or both?
3. Is chat a panel, a sheet, or a command bar ("Ask Fern…") over the board?
4. Can the person rearrange and resize cards themselves, or only ask the
   helper to?
5. What does Home look like when there are many topics: a timeline, a day
   view, a list of "needs you"?
6. How visible should the helper be as a character (name, avatar, voice)?
