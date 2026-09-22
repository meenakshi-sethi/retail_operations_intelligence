-- ============================================================
-- Retail Operations Intelligence: Sales, Returns & Inventory
-- Solutions — 19 business questions, PostgreSQL
--
-- Every query here was executed and verified against the data
-- (results cross-checked with an independent pandas implementation).
-- Fixes vs. the original tutorial queries are marked FIX.
-- ============================================================

-- 1. Top 10 products by total sales value
SELECT oi.product_id,
       p.product_name,
       ROUND(SUM(oi.total_sale), 2) AS total_sale,
       COUNT(*)                    AS total_orders
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p     ON p.product_id = oi.product_id
GROUP BY 1, 2
ORDER BY 3 DESC
LIMIT 10;

-- 2. Revenue by category with % contribution
SELECT p.category_id,
       c.category_name,
       ROUND(SUM(oi.total_sale), 2) AS total_sale,
       ROUND(SUM(oi.total_sale) / (SELECT SUM(total_sale) FROM order_items) * 100, 2) AS contribution_pct
FROM order_items oi
JOIN products p   ON p.product_id = oi.product_id
LEFT JOIN category c ON c.category_id = p.category_id
GROUP BY 1, 2
ORDER BY 3 DESC;

-- 3. Average Order Value per customer (only customers with > 5 orders)
SELECT c.customer_id,
       CONCAT(c.first_name, ' ', c.last_name) AS full_name,
       ROUND(SUM(oi.total_sale) / COUNT(DISTINCT o.order_id), 2) AS aov,
       COUNT(DISTINCT o.order_id) AS total_orders
FROM orders o
JOIN customers c    ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY 1, 2
HAVING COUNT(DISTINCT o.order_id) > 5
ORDER BY aov DESC;

-- 4. Monthly sales trend with month-over-month comparison
-- FIX: the original filtered order_date >= CURRENT_DATE - 1 year, which
-- returns ZERO rows on stale data. Anchor to the latest date in the data.
SELECT year,
       month,
       total_sale AS current_month_sale,
       LAG(total_sale, 1) OVER (ORDER BY year, month) AS last_month_sale
FROM (
  SELECT EXTRACT(YEAR  FROM o.order_date) AS year,
         EXTRACT(MONTH FROM o.order_date) AS month,
         ROUND(SUM(oi.total_sale), 2)     AS total_sale
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  WHERE o.order_date >= (SELECT MAX(order_date) FROM orders) - INTERVAL '1 year'
  GROUP BY 1, 2
) AS t1
ORDER BY year, month;

-- 5. Customers who registered but never placed an order
-- (Note: the customers table has no registration date, so "time since
-- registration" is not computable — this lists the customers only.)
SELECT c.*
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
WHERE o.customer_id IS NULL;

-- 6. Least-selling product category per state
WITH ranking_table AS (
  SELECT c.state,
         cat.category_name,
         SUM(oi.total_sale) AS total_sale,
         RANK() OVER (PARTITION BY c.state ORDER BY SUM(oi.total_sale) ASC) AS rank
  FROM orders o
  JOIN customers c    ON o.customer_id = c.customer_id
  JOIN order_items oi ON o.order_id = oi.order_id
  JOIN products p     ON oi.product_id = p.product_id
  JOIN category cat   ON cat.category_id = p.category_id
  GROUP BY 1, 2
)
SELECT * FROM ranking_table WHERE rank = 1;

-- 7. Customer Lifetime Value with ranking
SELECT c.customer_id,
       CONCAT(c.first_name, ' ', c.last_name) AS full_name,
       ROUND(SUM(oi.total_sale), 2) AS cltv,
       DENSE_RANK() OVER (ORDER BY SUM(oi.total_sale) DESC) AS cx_ranking
FROM orders o
JOIN customers c    ON c.customer_id = o.customer_id
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY 1, 2
ORDER BY cx_ranking;

-- 8. Inventory stock alerts (stock < 10 units)
SELECT i.inventory_id,
       p.product_name,
       i.stock AS current_stock_left,
       i.last_stock_date,
       i.warehouse_id
FROM inventory i
JOIN products p ON p.product_id = i.product_id
WHERE i.stock < 10
ORDER BY i.stock;

-- 9. Shipping delays: orders shipped more than 3 days after ordering
SELECT o.order_id,
       s.shipping_providers,
       s.shipping_date - o.order_date AS days_took_to_ship
FROM orders o
JOIN shippings s ON o.order_id = s.order_id
WHERE s.shipping_date - o.order_date > 3;

-- 10. Payment success rate with status breakdown
SELECT p.payment_status,
       COUNT(*) AS total_cnt,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM payments), 2) AS pct
FROM payments p
GROUP BY 1
ORDER BY 2 DESC;

-- 11. Top 5 sellers by sales value, with % of completed orders
WITH top_sellers AS (
  SELECT s.seller_id, s.seller_name, SUM(oi.total_sale) AS total_sale
  FROM orders o
  JOIN sellers s     ON o.seller_id = s.seller_id
  JOIN order_items oi ON oi.order_id = o.order_id
  GROUP BY 1, 2
  ORDER BY 3 DESC
  LIMIT 5
),
sellers_reports AS (
  SELECT o.seller_id, ts.seller_name, o.order_status, COUNT(*) AS total_orders
  FROM orders o
  JOIN top_sellers ts ON ts.seller_id = o.seller_id
  WHERE o.order_status NOT IN ('Inprogress', 'Returned')
  GROUP BY 1, 2, 3
)
SELECT seller_id,
       seller_name,
       SUM(CASE WHEN order_status = 'Completed' THEN total_orders ELSE 0 END) AS completed_orders,
       SUM(CASE WHEN order_status = 'Cancelled' THEN total_orders ELSE 0 END) AS cancelled_orders,
       SUM(total_orders) AS total_orders,
       ROUND(SUM(CASE WHEN order_status = 'Completed' THEN total_orders ELSE 0 END)
             * 100.0 / SUM(total_orders), 1) AS successful_orders_pct
FROM sellers_reports
GROUP BY 1, 2;

-- 12. Product profit margin, ranked
SELECT product_id, product_name,
       ROUND(profit_margin, 2) AS profit_margin,
       DENSE_RANK() OVER (ORDER BY profit_margin DESC) AS product_ranking
FROM (
  SELECT p.product_id, p.product_name,
         SUM(oi.total_sale - (p.cogs * oi.quantity)) / SUM(oi.total_sale) * 100 AS profit_margin
  FROM order_items oi
  JOIN products p ON oi.product_id = p.product_id
  GROUP BY 1, 2
) AS t1;

-- 13. Most returned products
-- FIX: added a minimum sample size (>= 20 units sold). Without it, a product
-- with 1 unit sold and 1 return shows a meaningless "100% return rate".
SELECT p.product_id,
       p.product_name,
       SUM(oi.quantity) AS total_units_sold,
       SUM(CASE WHEN o.order_status = 'Returned' THEN oi.quantity ELSE 0 END) AS total_returned,
       ROUND(SUM(CASE WHEN o.order_status = 'Returned' THEN oi.quantity ELSE 0 END)
             * 100.0 / SUM(oi.quantity), 1) AS return_pct
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
JOIN orders o   ON o.order_id = oi.order_id
GROUP BY 1, 2
HAVING SUM(oi.quantity) >= 20
ORDER BY return_pct DESC
LIMIT 10;

-- 14. Orders pending shipment
-- FIX: this problem was listed but never solved in the original project.
SELECT o.order_id,
       o.order_date,
       o.order_status,
       s.shipping_providers
FROM orders o
LEFT JOIN shippings s ON s.order_id = o.order_id
WHERE s.shipping_id IS NULL
   OR s.shipping_date IS NULL;

-- 15. Inactive sellers (no sales in the last 6 months of data)
-- FIX: anchored to MAX(order_date) instead of CURRENT_DATE — with stale data,
-- CURRENT_DATE makes every seller "inactive".
WITH last_active AS (
  SELECT seller_id, MAX(order_date) AS last_sale_date
  FROM orders GROUP BY 1
)
SELECT s.seller_id, s.seller_name, la.last_sale_date
FROM sellers s
JOIN last_active la ON la.seller_id = s.seller_id
WHERE la.last_sale_date < (SELECT MAX(order_date) FROM orders) - INTERVAL '6 month';

-- 16. Segment customers into returning vs. new
-- (> 5 returns = returning)
SELECT customer_name, total_orders, total_return,
       CASE WHEN total_return > 5 THEN 'Returning' ELSE 'New' END AS cx_category
FROM (
  SELECT CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
         COUNT(DISTINCT o.order_id) AS total_orders,
         SUM(CASE WHEN o.order_status = 'Returned' THEN 1 ELSE 0 END) AS total_return
  FROM orders o
  JOIN customers c ON c.customer_id = o.customer_id
  GROUP BY 1
) AS t;

-- 17. Top 5 customers by order count in each state
SELECT * FROM (
  SELECT c.state,
         CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
         COUNT(DISTINCT o.order_id) AS total_orders,
         ROUND(SUM(oi.total_sale), 2) AS total_sale,
         DENSE_RANK() OVER (PARTITION BY c.state ORDER BY COUNT(DISTINCT o.order_id) DESC) AS rank
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  JOIN customers c    ON c.customer_id = o.customer_id
  GROUP BY 1, 2
) AS t1
WHERE rank <= 5;

-- 18. Revenue by shipping provider with delay and delivery rates
-- FIX: the original computed AVG(return_date - shipping_date) and labeled it
-- "average delivery time" — that is the average ship-to-RETURN interval on the
-- 13% of shipments that were returned, not delivery time. There is no delivery
-- date in the data, so this version reports delay rate and delivered rate,
-- which the data does support.
SELECT s.shipping_providers,
       COUNT(*) AS orders_handled,
       ROUND(SUM(oi.total_sale), 2) AS total_sale,
       ROUND(SUM(CASE WHEN s.shipping_date - o.order_date > 3 THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1) AS delay_pct,
       ROUND(SUM(CASE WHEN s.delivery_status = 'Delivered' THEN 1 ELSE 0 END)
             * 100.0 / COUNT(*), 1) AS delivered_pct
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN shippings s    ON s.order_id = o.order_id
GROUP BY 1
ORDER BY total_sale DESC;

-- 19. Top 10 products with the highest revenue decline (2022 -> 2023)
-- FIX (two bugs in the original):
--   a) float noise: products with IDENTICAL revenue passed "ls > cs" by ~1e-12.
--      Fixed by rounding before comparison.
--   b) ORDER BY ratio DESC put 0.00% "declines" at the TOP of the list.
--      The biggest decline is the most NEGATIVE ratio -> sort ASC.
WITH last_year_sale AS (
  SELECT p.product_id, p.product_name, ROUND(SUM(oi.total_sale), 2) AS revenue
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  JOIN products p     ON p.product_id = oi.product_id
  WHERE EXTRACT(YEAR FROM o.order_date) = 2022
  GROUP BY 1, 2
),
current_year_sale AS (
  SELECT p.product_id, p.product_name, ROUND(SUM(oi.total_sale), 2) AS revenue
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  JOIN products p     ON p.product_id = oi.product_id
  WHERE EXTRACT(YEAR FROM o.order_date) = 2023
  GROUP BY 1, 2
)
SELECT cs.product_id,
       cs.product_name,
       ls.revenue AS last_year_revenue,
       cs.revenue AS current_year_revenue,
       ROUND((cs.revenue - ls.revenue) / ls.revenue * 100, 2) AS revenue_change_pct
FROM last_year_sale ls
JOIN current_year_sale cs ON ls.product_id = cs.product_id
WHERE ls.revenue > cs.revenue + 0.01
ORDER BY revenue_change_pct ASC
LIMIT 10;

-- 20. Full monthly revenue trend with a 3-month trailing moving average
-- (used to smooth the raw month-to-month noise on the revenue trend chart
-- so the underlying direction — up, down, flattening — reads at a glance).
SELECT year,
       month,
       total_sale AS monthly_revenue,
       ROUND(AVG(total_sale) OVER (
         ORDER BY year, month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
       ), 2) AS rolling_3mo_avg
FROM (
  SELECT EXTRACT(YEAR  FROM o.order_date) AS year,
         EXTRACT(MONTH FROM o.order_date) AS month,
         ROUND(SUM(oi.total_sale), 2)     AS total_sale
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.order_id
  GROUP BY 1, 2
) AS t1
ORDER BY year, month;
