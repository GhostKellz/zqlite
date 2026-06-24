WITH active_users AS (SELECT id FROM users WHERE active = 1) SELECT id FROM active_users;
