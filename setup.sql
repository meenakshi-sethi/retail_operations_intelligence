-- ============================================================
-- Retail Operations Intelligence: Sales, Returns & Inventory
-- Setup script — PostgreSQL (tested on Supabase / PG 14+)
--
-- Run order:
--   1. Create tables (schema below)
--   2. Import the CSVs in /datasets (Supabase: Database > Table Editor
--      or use the CSV import; local: \copy commands at the bottom)
--   3. Run the ALTER/UPDATE to derive total_sale
--   4. Create indexes, views, and the stored procedure
-- ============================================================

-- ---------- SCHEMA ----------
CREATE TABLE category (
  category_id   INT PRIMARY KEY,
  category_name VARCHAR(20)
);

CREATE TABLE customers (
  customer_id INT PRIMARY KEY,
  first_name  VARCHAR(20),
  last_name   VARCHAR(20),
  state       VARCHAR(20),
  address     VARCHAR(5) DEFAULT ('xxxx')
);

CREATE TABLE sellers (
  seller_id   INT PRIMARY KEY,
  seller_name VARCHAR(25),
  origin      VARCHAR(15)
);

CREATE TABLE products (
  product_id  INT PRIMARY KEY,
  product_name VARCHAR(50),
  price       FLOAT,
  cogs        FLOAT,
  category_id INT,
  CONSTRAINT product_fk_category FOREIGN KEY (category_id) REFERENCES category(category_id)
);

CREATE TABLE orders (
  order_id     INT PRIMARY KEY,
  order_date   DATE,
  customer_id  INT,
  seller_id    INT,
  order_status VARCHAR(15),
  CONSTRAINT orders_fk_customers FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
  CONSTRAINT orders_fk_sellers   FOREIGN KEY (seller_id)   REFERENCES sellers(seller_id)
);

CREATE TABLE order_items (
  order_item_id INT PRIMARY KEY,
  order_id      INT,
  product_id    INT,
  quantity      INT,
  price_per_unit FLOAT,
  CONSTRAINT order_items_fk_orders  FOREIGN KEY (order_id)  REFERENCES orders(order_id),
  CONSTRAINT order_items_fk_products FOREIGN KEY (product_id) REFERENCES products(product_id)
);

CREATE TABLE payments (
  payment_id     INT PRIMARY KEY,
  order_id       INT,
  payment_date   DATE,
  payment_status VARCHAR(20),
  CONSTRAINT payments_fk_orders FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

CREATE TABLE shippings (
  shipping_id        INT PRIMARY KEY,
  order_id           INT,
  shipping_date      DATE,
  return_date        DATE,
  shipping_providers VARCHAR(15),
  delivery_status    VARCHAR(15),
  CONSTRAINT shippings_fk_orders FOREIGN KEY (order_id) REFERENCES orders(order_id)
);

CREATE TABLE inventory (
  inventory_id    INT PRIMARY KEY,
  product_id      INT,
  stock           INT,
  warehouse_id    INT,
  last_stock_date DATE,
  CONSTRAINT inventory_fk_products FOREIGN KEY (product_id) REFERENCES products(product_id)
);

-- ---------- DERIVED COLUMN ----------
-- total_sale = quantity * price_per_unit (derived, not stored in the raw CSV)
ALTER TABLE order_items ADD COLUMN IF NOT EXISTS total_sale FLOAT;
UPDATE order_items SET total_sale = quantity * price_per_unit;

-- ---------- INDEXES ----------
-- Join/filter columns used by the analytical queries.
-- NOTE: at ~88K rows the planner may still prefer Seq Scans for some queries —
-- that is correct optimizer behavior at small scale. Verify with EXPLAIN ANALYZE.
CREATE INDEX IF NOT EXISTS idx_orders_order_date   ON orders (order_date);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id  ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_seller_id    ON orders (seller_id);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id   ON order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id ON order_items (product_id);
CREATE INDEX IF NOT EXISTS idx_shippings_order_id  ON shippings (order_id);
CREATE INDEX IF NOT EXISTS idx_payments_order_id   ON payments (order_id);
CREATE INDEX IF NOT EXISTS idx_inventory_product_id ON inventory (product_id);

-- ---------- VIEWS (recurring KPI layer) ----------
-- Leadership queries a view instead of re-running 9-table joins.

CREATE OR REPLACE VIEW v_category_revenue AS
SELECT c.category_name,
       SUM(oi.total_sale) AS revenue,
       ROUND(SUM(oi.total_sale) / (SELECT SUM(total_sale) FROM order_items) * 100, 1) AS contribution_pct
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category c ON c.category_id = p.category_id
GROUP BY 1
ORDER BY 2 DESC;

CREATE OR REPLACE VIEW v_customer_cltv AS
SELECT c.customer_id,
       CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
       c.state,
       SUM(oi.total_sale) AS cltv,
       COUNT(DISTINCT o.order_id) AS total_orders,
       DENSE_RANK() OVER (ORDER BY SUM(oi.total_sale) DESC) AS cltv_rank
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY 1, 2, 3;

CREATE OR REPLACE VIEW v_return_rates AS
SELECT p.product_id,
       p.product_name,
       SUM(oi.quantity) AS units_sold,
       SUM(CASE WHEN o.order_status = 'Returned' THEN oi.quantity ELSE 0 END) AS units_returned,
       ROUND(SUM(CASE WHEN o.order_status = 'Returned' THEN oi.quantity ELSE 0 END)
             * 100.0 / SUM(oi.quantity), 1) AS return_pct
FROM order_items oi
JOIN orders o ON o.order_id = oi.order_id
JOIN products p ON p.product_id = oi.product_id
GROUP BY 1, 2
HAVING SUM(oi.quantity) >= 20;  -- minimum sample size: avoids "100% return rate" on 1-unit products

CREATE OR REPLACE VIEW v_stock_alerts AS
SELECT i.inventory_id,
       p.product_name,
       i.stock AS current_stock_left,
       i.warehouse_id,
       i.last_stock_date
FROM inventory i
JOIN products p ON p.product_id = i.product_id
WHERE i.stock < 10;

CREATE OR REPLACE VIEW v_shipping_performance AS
SELECT s.shipping_providers,
       COUNT(*) AS shipments,
       SUM(CASE WHEN s.shipping_date - o.order_date > 3 THEN 1 ELSE 0 END) AS delayed_shipments,
       ROUND(SUM(CASE WHEN s.shipping_date - o.order_date > 3 THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1) AS delay_pct,
       ROUND(SUM(CASE WHEN s.delivery_status = 'Delivered' THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1) AS delivered_pct,
       SUM(oi.total_sale) AS revenue_handled
FROM shippings s
JOIN orders o ON o.order_id = s.order_id
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY 1;

-- ---------- STORED PROCEDURE (hardened) ----------
-- Records a sale and decrements inventory atomically.
-- Fixes vs. the original version:
--   1. SELECT ... FOR UPDATE locks the inventory row -> no race condition
--      between two concurrent sales both passing the stock check.
--   2. Decrements only the locked warehouse row (original updated every
--      warehouse row for the product).
--   3. Inserts an explicit order_status ('Completed') instead of NULL.

CREATE OR REPLACE PROCEDURE add_sales(
  p_order_id      INT,
  p_customer_id   INT,
  p_seller_id     INT,
  p_order_item_id INT,
  p_product_id    INT,
  p_quantity      INT
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_price     FLOAT;
  v_product   VARCHAR(50);
  v_inventory inventory%ROWTYPE;
BEGIN
  -- product info
  SELECT price, product_name INTO v_price, v_product
  FROM products WHERE product_id = p_product_id;

  IF v_product IS NULL THEN
    RAISE EXCEPTION 'Product % not found', p_product_id;
  END IF;

  -- lock the inventory row FOR UPDATE (race-condition fix)
  SELECT * INTO v_inventory
  FROM inventory
  WHERE product_id = p_product_id
    AND stock >= p_quantity
  ORDER BY stock DESC
  FOR UPDATE;

  IF v_inventory.inventory_id IS NULL THEN
    RAISE EXCEPTION 'Insufficient stock for product % (requested %)', v_product, p_quantity;
  END IF;

  -- record the sale
  INSERT INTO orders (order_id, order_date, customer_id, seller_id, order_status)
  VALUES (p_order_id, CURRENT_DATE, p_customer_id, p_seller_id, 'Completed');

  INSERT INTO order_items (order_item_id, order_id, product_id, quantity, price_per_unit, total_sale)
  VALUES (p_order_item_id, p_order_id, p_product_id, p_quantity, v_price, v_price * p_quantity);

  -- decrement only the locked warehouse row
  UPDATE inventory
  SET stock = stock - p_quantity,
      last_stock_date = CURRENT_DATE
  WHERE inventory_id = v_inventory.inventory_id;

  RAISE NOTICE 'Sale recorded for % — inventory % updated (stock now %).',
    v_product, v_inventory.inventory_id, v_inventory.stock - p_quantity;
END;
$$;

-- Test call (adjust IDs to your data):
-- CALL add_sales(25005, 2, 5, 25004, 1, 14);

-- ---------- LOCAL IMPORT (psql) ----------
-- \copy customers   FROM 'datasets/customers.csv'   CSV HEADER
-- \copy products    FROM 'datasets/products.csv'    CSV HEADER
-- \copy category    FROM 'datasets/category.csv'    CSV HEADER
-- \copy sellers     FROM 'datasets/sellers.csv'     CSV HEADER
-- \copy orders      FROM 'datasets/orders.csv'      CSV HEADER
-- \copy order_items FROM 'datasets/order_items.csv' CSV HEADER
-- \copy payments    FROM 'datasets/payments.csv'    CSV HEADER
-- \copy shippings   FROM 'datasets/shipping.csv'    CSV HEADER
-- \copy inventory   FROM 'datasets/inventory.csv'   CSV HEADER
