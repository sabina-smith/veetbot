-- The Household topic's database as first created.

CREATE TABLE bills (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  due_on TEXT,
  amount REAL NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'due' CHECK (status IN ('autopay', 'due', 'paid', 'flag', 'cancelled')),
  note TEXT
);

CREATE TABLE upkeep (
  id INTEGER PRIMARY KEY,
  task TEXT NOT NULL,
  every TEXT NOT NULL,
  every_days INTEGER NOT NULL,
  last_done TEXT,
  status TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'looking', 'booked')),
  note TEXT
);

CREATE TABLE errands (
  id INTEGER PRIMARY KEY,
  text TEXT NOT NULL,
  tag TEXT,
  done INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE people (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  role TEXT,
  how TEXT,
  note TEXT
);
