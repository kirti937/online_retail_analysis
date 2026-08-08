CREATE TABLE online_retail (
    InvoiceNo     VARCHAR(20),
    StockCode     VARCHAR(20),
    Description   VARCHAR(255),
    Quantity      INT,
    InvoiceDate   TIMESTAMP,
    UnitPrice     DECIMAL(10,2),
    CustomerID    INT,
    Country       VARCHAR(100)
);



-- ---------------------------------------------------------

-- Missing values per column
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN Description IS NULL THEN 1 ELSE 0 END) AS missing_description,
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END)  AS missing_customer_id
FROM online_retail;

-- Cancelled orders (InvoiceNo starting with 'C')
SELECT COUNT(*) AS cancelled_rows
FROM online_retail
WHERE InvoiceNo LIKE 'C%';

-- Invalid rows (negative qty or non-positive price)
SELECT
    SUM(CASE WHEN Quantity <= 0 THEN 1 ELSE 0 END)  AS non_positive_qty,
    SUM(CASE WHEN UnitPrice <= 0 THEN 1 ELSE 0 END) AS non_positive_price
FROM online_retail;


-- ---------------------------------------------------------
-- 3. CLEAN VIEW (used by all downstream queries)
-- ---------------------------------------------------------
DROP VIEW IF EXISTS online_retail_clean;

CREATE VIEW online_retail_clean AS
SELECT
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    UnitPrice,
    CustomerID,
    Country,
    Quantity * UnitPrice AS Revenue
FROM online_retail
WHERE InvoiceNo NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0;


-- ---------------------------------------------------------
-- 4. KEY KPIs
-- ---------------------------------------------------------
SELECT
    ROUND(SUM(Revenue), 2)          AS total_revenue,
    COUNT(DISTINCT InvoiceNo)       AS total_orders,
    COUNT(DISTINCT CustomerID)      AS total_customers,
    ROUND(SUM(Revenue) / COUNT(DISTINCT InvoiceNo), 2) AS avg_order_value
FROM online_retail_clean;


-- ---------------------------------------------------------
-- 5. TOP 10 PRODUCTS BY REVENUE
-- ---------------------------------------------------------
SELECT
    StockCode,
    Description,
    SUM(Quantity)         AS units_sold,
    ROUND(SUM(Revenue),2) AS total_revenue
FROM online_retail_clean
GROUP BY StockCode, Description
ORDER BY total_revenue DESC
LIMIT 10;   -- SQL Server: use TOP 10 instead of LIMIT


-- ---------------------------------------------------------
-- 6. REVENUE BY COUNTRY
-- ---------------------------------------------------------
SELECT
    Country,
    COUNT(DISTINCT InvoiceNo)  AS orders,
    ROUND(SUM(Revenue), 2)     AS total_revenue,
    ROUND(SUM(Revenue) * 100.0 / SUM(SUM(Revenue)) OVER (), 2) AS pct_of_total
FROM online_retail_clean
GROUP BY Country
ORDER BY total_revenue DESC;


-- ---------------------------------------------------------
-- 7. MONTHLY SALES TREND
-- ---------------------------------------------------------
SELECT
    DATE_TRUNC('month', InvoiceDate) AS sales_month,     -- MySQL: DATE_FORMAT(InvoiceDate,'%Y-%m-01')
    ROUND(SUM(Revenue), 2)           AS monthly_revenue,
    COUNT(DISTINCT InvoiceNo)        AS orders
FROM online_retail_clean
GROUP BY DATE_TRUNC('month', InvoiceDate)
ORDER BY sales_month;


-- ---------------------------------------------------------
-- 8. MONTH-OVER-MONTH GROWTH
-- ---------------------------------------------------------
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', InvoiceDate) AS sales_month,
        SUM(Revenue) AS revenue
    FROM online_retail_clean
    GROUP BY DATE_TRUNC('month', InvoiceDate)
)
SELECT
    sales_month,
    ROUND(revenue, 2) AS revenue,
    ROUND(revenue - LAG(revenue) OVER (ORDER BY sales_month), 2) AS mom_change,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY sales_month))
          / NULLIF(LAG(revenue) OVER (ORDER BY sales_month), 0), 2) AS mom_pct_change
FROM monthly
ORDER BY sales_month;


-- ---------------------------------------------------------
-- 9. TOP 10 CUSTOMERS BY REVENUE
-- ---------------------------------------------------------
SELECT
    CustomerID,
    Country,
    COUNT(DISTINCT InvoiceNo)  AS num_orders,
    ROUND(SUM(Revenue), 2)     AS total_revenue
FROM online_retail_clean
WHERE CustomerID IS NOT NULL
GROUP BY CustomerID, Country
ORDER BY total_revenue DESC
LIMIT 10;


-- ---------------------------------------------------------
-- 10. RFM ANALYSIS (Recency, Frequency, Monetary)
-- ---------------------------------------------------------
WITH snapshot AS (
    SELECT MAX(InvoiceDate) + INTERVAL '1 day' AS snapshot_date   -- SQL Server: DATEADD(day,1,MAX(InvoiceDate))
    FROM online_retail_clean
),
rfm_base AS (
    SELECT
        c.CustomerID,
        DATEDIFF('day', MAX(c.InvoiceDate), s.snapshot_date) AS recency_days,  -- Postgres: (s.snapshot_date - MAX(c.InvoiceDate))
        COUNT(DISTINCT c.InvoiceNo)                           AS frequency,
        SUM(c.Revenue)                                        AS monetary
    FROM online_retail_clean c
    CROSS JOIN snapshot s
    WHERE c.CustomerID IS NOT NULL
    GROUP BY c.CustomerID, s.snapshot_date
),
rfm_scored AS (
    SELECT
        CustomerID,
        recency_days,
        frequency,
        ROUND(monetary, 2) AS monetary,
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(4) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_base
)
SELECT
    *,
    (r_score + f_score + m_score) AS rfm_total,
    CASE
        WHEN (r_score + f_score + m_score) >= 10 THEN 'Champions'
        WHEN (r_score + f_score + m_score) >= 8  THEN 'Loyal'
        WHEN (r_score + f_score + m_score) >= 6  THEN 'Potential'
        WHEN (r_score + f_score + m_score) >= 4  THEN 'At Risk'
        ELSE 'Lost'
    END AS segment
FROM rfm_scored
ORDER BY monetary DESC;


-- ---------------------------------------------------------
-- 11. REPEAT VS ONE-TIME CUSTOMERS
-- ---------------------------------------------------------
WITH order_counts AS (
    SELECT CustomerID, COUNT(DISTINCT InvoiceNo) AS orders
    FROM online_retail_clean
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
)
SELECT
    CASE WHEN orders = 1 THEN 'One-time' ELSE 'Repeat' END AS customer_type,
    COUNT(*) AS num_customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_customers
FROM order_counts
GROUP BY CASE WHEN orders = 1 THEN 'One-time' ELSE 'Repeat' END;


-- ---------------------------------------------------------
-- 12. SALES BY DAY OF WEEK / HOUR (for seasonality dashboards)
-- ---------------------------------------------------------
SELECT
    TO_CHAR(InvoiceDate, 'Day')            AS day_of_week,   -- MySQL: DAYNAME(InvoiceDate)
    EXTRACT(HOUR FROM InvoiceDate)         AS hour_of_day,
    ROUND(SUM(Revenue), 2)                 AS revenue
FROM online_retail_clean
GROUP BY TO_CHAR(InvoiceDate, 'Day'), EXTRACT(HOUR FROM InvoiceDate)
ORDER BY revenue DESC;

SELECT FROM online_retail_clean
SHOW Tables;