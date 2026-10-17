-- Demo data for Mahi Stores.
--
-- order #1042 (Alice, headphones, £89) is beat 1's refund.
-- order #1045 (Alice, charger x2, £64) is beat 2's refund -- deliberately a
-- DIFFERENT order than beat 1's, so scripts/demo-beat{1,2}.sh can run
-- back-to-back without scripts/reset.sh in between and neither hits
-- "already refunded." Both are under the £100 auto-approval threshold.
-- order #1046 (Bob, charger, £32) is the "wrong customer" refund both
-- beat 1 (succeeds -- the point) and beat 2 (denied -- the point) attempt
-- while chatting as Alice. Also under threshold, so the point stays
-- overprivilege/ownership, not the approval gate.
-- order #1043 (Bob, keyboard, £125) and #1044 (Carol, monitor, £450) sit
-- above the threshold for exercising the approval flow itself.

INSERT INTO customers (customer_id, name, email, phone) VALUES
    (1, 'Alice Chen',   'alice@example.com',   '+44 7700 900001'),
    (2, 'Bob Okafor',   'bob@example.com',     '+44 7700 900002'),
    (3, 'Carol Novak',  'carol@example.com',   '+44 7700 900003')
ON CONFLICT (customer_id) DO NOTHING;

-- Products 5-10 are additive only -- do not renumber 1-4, the orders below
-- reference them by id, and scripts/demo-beat{1,2,3}.sh reference those
-- orders by id in turn. These exist to make the catalog grid look like a
-- real shop's worth of inventory, not a 4-item demo fixture.
INSERT INTO products (product_id, name, description, price_pence, stock) VALUES
    (1,  'Wireless Headphones',  'Over-ear, 30h battery, active noise cancelling', 8900,  42),
    (2,  'Mechanical Keyboard',  'Hot-swappable switches, USB-C',                   12500, 30),
    (3,  '27" Monitor',          '4K IPS, 144Hz',                                   45000, 12),
    (4,  'USB-C Charger 65W',    'GaN, compact',                                     3200, 80),
    (5,  'Wireless Mouse',       'Silent click, 6-month battery',                    3500, 65),
    (6,  'Laptop Stand',         'Aluminium, folds flat',                            4200, 38),
    (7,  '1080p Webcam',         'Autofocus, built-in mic',                          5600, 24),
    (8,  'Bluetooth Speaker',    'IPX7 water-resistant, 12h playback',               6900, 50),
    (9,  'Laptop Sleeve 14"',    'Padded, water-repellent',                          2400, 90),
    (10, 'USB-C Hub',            '7-in-1, HDMI + card reader',                       4800, 55)
ON CONFLICT (product_id) DO NOTHING;

INSERT INTO orders (order_id, customer_id, product_id, quantity, total_pence, status, placed_at) VALUES
    (1042, 1, 1, 1, 8900,  'delivered', now() - interval '6 days'),
    (1043, 2, 2, 1, 12500, 'delivered', now() - interval '4 days'),
    (1044, 3, 3, 1, 45000, 'delivered', now() - interval '2 days'),
    (1045, 1, 4, 2, 6400,  'shipped',   now() - interval '1 day'),
    (1046, 2, 4, 1, 3200,  'delivered', now() - interval '3 days')
ON CONFLICT (order_id) DO NOTHING;

SELECT setval('orders_order_id_seq', (SELECT MAX(order_id) FROM orders));
SELECT setval('customers_customer_id_seq', (SELECT MAX(customer_id) FROM customers));
SELECT setval('products_product_id_seq', (SELECT MAX(product_id) FROM products));
