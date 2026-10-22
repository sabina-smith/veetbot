-- Sample data for a first look at the Household board.

INSERT INTO bills (id, name, due_on, amount, status, note) VALUES
  (1, 'Rent', '2026-11-01', 3450, 'autopay', NULL),
  (2, 'Internet · Comcast', '2026-10-30', 95, 'due', 'was $80'),
  (3, 'Water · EBMUD', '2026-10-21', 68.40, 'due', NULL),
  (4, 'Power · PG&E', '2026-10-28', 142.18, 'autopay', NULL),
  (5, 'Peacock', '2026-11-04', 13.99, 'flag', 'Not opened since July'),
  (6, 'Renters insurance · Lemonade', '2026-11-12', 14, 'autopay', NULL);

INSERT INTO upkeep (task, every, every_days, last_done, status, note) VALUES
  ('Dryer vent cleaning', 'Yearly', 365, '2025-09-15', 'ok', NULL),
  ('Gutters', 'Before the rain', 365, '2025-11-01', 'ok', NULL),
  ('HVAC filter, 16×25×1', 'Every 3 months', 91, '2026-08-01', 'ok', NULL),
  ('Smoke alarm batteries', 'Yearly', 365, '2025-11-01', 'ok', NULL),
  ('Water heater flush', 'Yearly', 365, '2026-03-10', 'ok', NULL);

INSERT INTO errands (text, tag, done) VALUES
  ('Oat milk', 'Running low', 0),
  ('Dish soap, the unscented one', NULL, 0),
  ('HVAC filter 16×25×1, ×2', NULL, 0),
  ('Drop off dry cleaning', 'Errand', 0),
  ('Coffee beans', NULL, 1);

INSERT INTO people (name, role, how, note) VALUES
  ('Luis Ortega', 'Plumber', 'Text, not calls', 'Fixed the kitchen sink in May. Cash or Venmo.'),
  ('Maya', 'Neighbour, 2B', 'Text', 'Has the spare key. Waters plants when you travel.'),
  ('Grove St Property Mgmt', 'Landlord', 'Email, keep it short', 'Repairs over $200 go through them first.');

INSERT INTO proposals (ref, kind, title, summary, options, recommended) VALUES
  ('bills/2', 'choice', 'Internet went up $15',
   'Comcast''s promo ended. Sonic is cheaper and faster, and the install fits a Tuesday, when you work from home.',
   '[{"label": "Stay on Comcast 300", "detail": "No change. Goes up again in April.", "price": 95, "set": {"note": "Staying on Comcast"}},
     {"label": "Ask Comcast for a retention deal", "detail": "Hollis writes what to say, you call. Usually works; about 20 minutes.", "price": 80, "set": {"note": "Call Comcast for a deal"}},
     {"label": "Switch to Sonic Fiber 1 Gig", "detail": "No contract, free install Tue Nov 3. Return the Comcast modem after.", "url": "https://www.sonic.com", "price": 55, "set": {"note": "Switching to Sonic, install Tue Nov 3"}}]',
   2);
