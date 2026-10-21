-- Sample data for a first look at the Garden board.

INSERT INTO beds (id, name, x, y, w, h, sun, soil, notes) VALUES
  (1, 'North bed', 8, 8, 44, 16, 'full', 'Raised, loam', 'Tomatoes did well here this summer.'),
  (2, 'Herb corner', 62, 8, 22, 22, 'full', 'Sandy', NULL),
  (3, 'South bed', 8, 44, 44, 16, 'part', 'Clay, needs compost', 'Shaded after 3pm by the maple.'),
  (4, 'Berry row', 62, 50, 50, 10, 'full', NULL, NULL),
  (5, 'Fig corner', 94, 10, 18, 18, 'full', NULL, 'Protect from frost in November.');

INSERT INTO plants (bed_id, name, variety, status, planted_on, notes) VALUES
  (1, 'Tomato', 'Sungold', 'harvested', '2026-05-10', 'Pull vines before frost.'),
  (1, 'Tomato', 'Brandywine', 'harvested', '2026-05-10', NULL),
  (1, 'Kale', 'Lacinato', 'growing', '2026-08-20', NULL),
  (1, 'Garlic', 'Music', 'planned', NULL, 'Plant cloves late October.'),
  (2, 'Basil', 'Genovese', 'harvested', '2026-05-15', NULL),
  (2, 'Rosemary', NULL, 'growing', '2025-04-02', NULL),
  (2, 'Thyme', NULL, 'growing', '2025-04-02', NULL),
  (2, 'Lavender', 'Hidcote', 'growing', '2025-04-02', NULL),
  (3, 'Lettuce', 'Butterhead', 'growing', '2026-09-05', NULL),
  (3, 'Spinach', NULL, 'growing', '2026-09-05', NULL),
  (4, 'Raspberry', 'Heritage', 'dormant', '2024-03-30', 'Cut fall canes to the ground after fruiting.'),
  (4, 'Blueberry', 'Bluecrop', 'dormant', '2024-03-30', NULL),
  (5, 'Fig', 'Chicago Hardy', 'growing', '2023-05-01', NULL);

INSERT INTO tools (name, category, condition, location, notes) VALUES
  ('Trowel', 'Hand tools', 'good', 'Shed, pegboard', NULL),
  ('Hand pruners', 'Cutting', 'worn', 'Shed, pegboard', 'Blade is dull; spring is weak.'),
  ('Loppers', 'Cutting', 'good', 'Shed, back wall', NULL),
  ('Garden fork', 'Digging', 'good', 'Shed, corner', NULL),
  ('Spade', 'Digging', 'good', 'Shed, corner', NULL),
  ('Leaf rake', 'Raking', 'broken', 'Shed, corner', 'Three tines snapped.'),
  ('Hose, 50 ft', 'Watering', 'good', 'Side of house', NULL),
  ('Watering can', 'Watering', 'good', 'Shed', NULL),
  ('Wheelbarrow', 'Hauling', 'worn', 'Behind shed', 'Tire loses air.');

INSERT INTO tasks (id, title, notes, assignee, status, due_on) VALUES
  (1, 'Plant garlic in the north bed', 'After pulling the tomato vines.', 'me', 'open', '2026-10-31'),
  (2, 'Pull tomato vines', NULL, 'me', 'open', '2026-10-25'),
  (3, 'Find compost for the south bed', 'About 3 cubic feet; clay soil.', 'agent', 'open', '2026-10-28'),
  (4, 'Wrap the fig before first frost', NULL, 'me', 'open', '2026-11-10'),
  (5, 'Cut back raspberry canes', NULL, 'me', 'open', NULL),
  (6, 'Sharpen the hand pruners', NULL, 'me', 'done', NULL);

INSERT INTO shopping (item, qty, status, source, price, task_id, notes, added_by) VALUES
  ('Garlic seed cloves', '1 lb', 'needed', NULL, NULL, 1, 'Hardneck, for zone 6.', 'me'),
  ('Compost', '3 cu ft', 'needed', NULL, NULL, 3, NULL, 'me'),
  ('Leaf rake', '1', 'needed', NULL, NULL, NULL, 'Replacing the broken one.', 'me'),
  ('Frost cloth', '10 x 12 ft', 'needed', NULL, NULL, 4, NULL, 'me');
