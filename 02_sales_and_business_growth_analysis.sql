/*
PROJECT: Maven Toys E-commerce Analysis
FILE: 02_sales_analysis.sql
AUTHOR: Karolina Marek
 
DESCRIPTION:
This script analyzes the overall financial health and growth trends of the business.
It constructs a Sales Table  optimized for BI tools like Power BI/Tableau.
 
KEY ANALYSES:
 1. Monthly growth & trends: Gross vs. net revenue, profitability, and KPI tracking.
 2. Customer retention: New vs. repeat customer behavior.
 3. Product performance: Net contribution and refund rates per SKU.
*/



-- 1. SALES TABLE (Growth, Trends & Financial KPIs)

/* Strategy:
 - Using CTE 'monthly_data' to pre-aggregate metrics at the monthly level.
 - HANDLING DATA GRANULARITY: Using a subquery for refunds joined on 'order_id' 
   to prevent data duplication (fan-out trap) when joining orders with multiple refund items.
 - Calculating both GROSS (Sales) and NET (Financial) metrics to provide a realistic view of profitability.
*/
DROP TABLE IF EXISTS bi_sales;

CREATE TABLE bi_sales AS

WITH monthly_data AS (
    SELECT 
        MIN(DATE(s.created_at)) AS month_start_date,
        COUNT(DISTINCT s.session_id) AS total_sessions,
        COUNT(DISTINCT o.order_id) AS total_orders,
        COUNT(DISTINCT r.order_id) AS refunds_num,
        
        -- 1. GROSS METRICS 
        COALESCE(SUM(o.price_usd), 0) AS gross_revenue,
        COALESCE(SUM(o.profit_gross), 0) AS gross_profit,
        
        -- 2. REFUNDS 
        COALESCE(SUM(r.refund_amt), 0) AS total_refunds,
        
        -- NET METRICS 
        -- Net Revenue = revenue - refunuds
        COALESCE(SUM(o.price_usd), 0) - COALESCE(SUM(r.refund_amt), 0) AS net_revenue,
        
        -- Net Profit = Profit gross - refunds (conservative approach: COGS not recoverable)
        COALESCE(SUM(o.profit_gross), 0) - COALESCE(SUM(r.refund_amt), 0) AS net_profit

    FROM website_sessions s
    LEFT JOIN orders o 
        ON s.session_id = o.website_session_id
	-- Pre-aggregating refunds to avoid duplicating revenue rows
    LEFT JOIN (
        SELECT order_id, SUM(refund_amount) AS refund_amt 
        FROM order_item_refunds 
        GROUP BY order_id
    ) r ON o.order_id = r.order_id
    
    GROUP BY 
        YEAR(s.created_at), 
        MONTH(s.created_at))

SELECT 
    month_start_date,
    total_sessions,
    total_orders,
    refunds_num,
    
    -- FINANCIALS ABSOLUTE
    gross_revenue,
    total_refunds,
    net_revenue,
    gross_profit,
    net_profit,
    
    -- RATIOS 
    -- Conversion Rate: Efficiency of turning traffic into sales
    ROUND(total_orders / NULLIF(total_sessions, 0) * 100, 2) AS conversion_rate,
    
    -- Revenue Per Session (net)
    ROUND(net_revenue / NULLIF(total_sessions, 0), 2) AS revenue_per_session,
    
    -- Average Order Value (gross): Understanding customer basket size intent
    ROUND(gross_revenue / NULLIF(total_orders, 0), 2) AS avg_order_value_gross,
    
    -- Refund Rate: Quality control metric (% of revenue returned)
    ROUND(total_refunds / NULLIF(gross_revenue, 0) * 100, 2) AS refund_rate_pct,
    
    -- Net Margin %: Actual profitability percentage after returns
    ROUND(net_profit / NULLIF(net_revenue, 0) * 100, 2) AS net_margin_pct,
    
    -- TRENDS
    -- Running Total (Net Revenue): Cumulative growth
    SUM(net_revenue) OVER (ORDER BY month_start_date) AS cumulative_net_revenue,
    
    -- 3-Month Moving Average (Net Revenue): Smoothing out short-term volatility to see the trend
    ROUND(AVG(net_revenue) OVER (ORDER BY month_start_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS net_rev_3m_moving_avg

FROM monthly_data
ORDER BY month_start_date;


-- =============================================================================
-- 2. CUSTOMER SEGMENTATION: NEW vs REPEAT
-- =============================================================================
/*
 Analyzing customer retention and the value of loyalty.
 Using Gross Revenue here to reflect the initial purchase intent (Basket Size).
*/
DROP TABLE IF EXISTS bi_sales_customers;

CREATE TABLE bi_sales_customers AS
SELECT 
	MIN(CAST(CONCAT(YEAR(o.created_at), '-', MONTH(o.created_at), '-01') AS DATE)) AS month_start_date,
    
    -- Volume Analysis
    COUNT(DISTINCT CASE WHEN s.is_repeat_session = 0 THEN o.order_id ELSE NULL END) AS new_orders,
    COUNT(DISTINCT CASE WHEN s.is_repeat_session = 1 THEN o.order_id ELSE NULL END) AS repeat_orders,
    
    -- Revenue Analysis
    COALESCE(SUM(CASE WHEN s.is_repeat_session = 0 THEN o.price_usd ELSE NULL END), 0) AS new_revenue,
    COALESCE(SUM(CASE WHEN s.is_repeat_session = 1 THEN o.price_usd ELSE NULL END), 0) AS repeat_revenue,
    
    -- Average Order Value Analysis (behavioral difference)
    COALESCE(ROUND(AVG(CASE WHEN s.is_repeat_session = 0 THEN o.price_usd ELSE NULL END), 2), 0) AS avg_order_value_new,
    COALESCE(ROUND(AVG(CASE WHEN s.is_repeat_session = 1 THEN o.price_usd ELSE NULL END), 2), 0) AS avg_order_value_repeat,

    -- Revenue Share from repeat customers
    ROUND(SUM(CASE WHEN s.is_repeat_session = 1 THEN o.price_usd ELSE 0 END) / NULLIF(SUM(o.price_usd), 0) * 100, 1) AS repeat_revenue_share_pct
FROM orders o
LEFT JOIN website_sessions s
ON o.website_session_id = s.session_id
GROUP BY YEAR(o.created_at), MONTH(o.created_at)
ORDER BY 1;


-- =============================================================================
-- 3. PRODUCT PERFORMANCE & CONTRIBUTION ANALYSIS
-- =============================================================================
/*
 Deep dive into Product Mix. Calculating Net metrics per product to identify 
 true profitability drivers, accounting for refunds and COGS.
 Uses Window Functions to calculate monthly market share dynamically.
*/

DROP TABLE IF EXISTS bi_sales_products;

CREATE TABLE bi_sales_products AS
WITH product_metrics AS (
    SELECT 
        MIN(CAST(CONCAT(YEAR(oi.created_at), '-', MONTH(oi.created_at), '-01') AS DATE)) AS month_start_date,
        YEAR(oi.created_at) AS yr, 
        MONTH(oi.created_at) AS mo,
        p.product_name,
        
        -- Volume & Gross
        COALESCE(COUNT(DISTINCT oi.order_id), 0) AS total_orders,
        COALESCE(COUNT(DISTINCT r.order_id), 0) AS refunds_num, 
        SUM(oi.price_usd) AS gross_revenue,
        
        -- Net Calculations
        COALESCE(SUM(r.refund_amount), 0) AS total_refunds,
        SUM(oi.price_usd) - COALESCE(SUM(r.refund_amount), 0) AS net_revenue,
        SUM(oi.price_usd - oi.cogs_usd) - COALESCE(SUM(r.refund_amount), 0) AS net_profit

    FROM order_items oi
    LEFT JOIN order_item_refunds r 
    ON oi.order_item_id = r.order_item_id
    LEFT JOIN products p 
    ON oi.product_id = p.product_id
    GROUP BY YEAR(oi.created_at), MONTH(oi.created_at), p.product_name
)

SELECT 
    month_start_date,
    product_name,
    total_orders,
    gross_revenue,
    refunds_num,
    total_refunds,
    net_revenue,
    net_profit,
    
    -- Quality metric: refund rate
    ROUND(total_refunds / gross_revenue * 100, 2) AS refund_rate_pct,
    
    -- Market share analysis
    ROUND(net_revenue / SUM(net_revenue) OVER(PARTITION BY yr, mo) * 100, 2) AS net_revenue_share_pct,
    
    -- Profit contribution
    ROUND(net_profit / SUM(net_profit) OVER(PARTITION BY yr, mo) * 100, 2) AS net_profit_share_pct
FROM product_metrics
ORDER BY month_start_date, net_revenue DESC;