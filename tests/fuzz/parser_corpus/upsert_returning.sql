INSERT INTO kv (k, v) VALUES ('a', 'b') ON CONFLICT(k) DO UPDATE SET v = 'c' RETURNING k, v;
