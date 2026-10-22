-- The Garden topic's database as first created. The live schema is
-- whatever data.sqlite holds now; the agent changes it with SQL blocks.

CREATE TABLE beds (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  -- Position and size on the map, in yard units (the map is 120 x 80).
  x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
  sun TEXT NOT NULL DEFAULT 'full' CHECK (sun IN ('full', 'part', 'shade')),
  soil TEXT,
  notes TEXT
);

CREATE TABLE plants (
  id INTEGER PRIMARY KEY,
  bed_id INTEGER REFERENCES beds(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  variety TEXT,
  status TEXT NOT NULL DEFAULT 'growing'
    CHECK (status IN ('planned', 'growing', 'dormant', 'harvested', 'removed')),
  planted_on TEXT,
  notes TEXT
);

CREATE TABLE tools (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'Hand tools',
  condition TEXT NOT NULL DEFAULT 'good' CHECK (condition IN ('good', 'worn', 'broken')),
  location TEXT,
  notes TEXT
);

CREATE TABLE tasks (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT,
  assignee TEXT NOT NULL DEFAULT 'me' CHECK (assignee IN ('me', 'agent')),
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'in_progress', 'waiting', 'done')),
  due_on TEXT,
  -- What the agent last did or found, shown under the task.
  agent_note TEXT,
  schedule_id TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  done_at TEXT
);

CREATE TABLE shopping (
  id INTEGER PRIMARY KEY,
  item TEXT NOT NULL,
  qty TEXT,
  status TEXT NOT NULL DEFAULT 'needed'
    CHECK (status IN ('needed', 'researching', 'in_cart', 'ordered', 'arrived')),
  source TEXT,
  url TEXT,
  price REAL,
  task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
  notes TEXT,
  added_by TEXT NOT NULL DEFAULT 'me' CHECK (added_by IN ('me', 'agent'))
);
