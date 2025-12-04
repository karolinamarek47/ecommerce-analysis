/*
PROJECT: Maven Toys E-commerce Analysis
FILE: 04_website_performance.sql
AUTHOR: Karolina Marek
 
DESCRIPTION:
This script focuses on User Experience and Conversion Rate Optimization.
It analyzes the customer journey to identify friction points and evaluates the success of design experiments.
 
KEY ANALYSES:
 1. Conversion funnel: Step-by-step drop-off analysis from Homepage to Thank You page.
 2. Landing page performance: Scaling analysis and trend monitoring for new landing pages.
 3. Billing page A/B test: Final results of the checkout page optimization experiment.
*/

-- =============================================================================
-- 1. CONVERSION FUNNEL ANALYSIS
-- =============================================================================
/*
Strategy:
 - Constructing a session-level flag table using MAX(CASE WHEN...) to map the user journey.
 - OBJECTIVE: Identify specific bottlenecks where customers abandon the process.
 - METRICS: Calculating Click-Through Rates (CTR) between each step relative to the previous step, 
   rather than overall conversion, to pinpoint exact friction areas (e.g., Cart abandonment).
*/

-- Flagging sessions for each funnel step (using temporary table for performance)
DROP TEMPORARY TABLE IF EXISTS website_performance;

CREATE TEMPORARY TABLE website_performance AS
SELECT 
	website_session_id,
    MIN(created_at) AS session_start_at,
    -- Step 1: All potential entry points (Home + Landers)
    MAX(CASE WHEN pageview_url IN ('/home','/lander-1','/lander-2','/lander-3','/lander-4','/lander-5') THEN 1 ELSE 0 END) AS saw_homepage,
	-- Step 2: Product selection
    MAX(CASE WHEN pageview_url = '/products' THEN 1 ELSE 0 END) AS saw_products,
    -- Step 3: Product detail
    MAX(CASE WHEN pageview_url IN ('/the-original-mr-fuzzy','/the-forever-love-bear','/the-birthday-sugar-panda','/the-hudson-river-mini-bear') THEN 1 ELSE 0 END) AS saw_product_page,
    -- Step 4: Intent to buy
    MAX(CASE WHEN pageview_url = '/cart' THEN 1 ELSE 0 END) AS saw_cart,
    -- Step 5: Shipping
    MAX(CASE WHEN pageview_url = '/shipping' THEN 1 ELSE 0 END) AS saw_shipping,
    -- Step 6: Payment (Checking both versions of billing page)
    MAX(CASE WHEN pageview_url IN ('/billing','/billing-2') THEN 1 ELSE 0 END) AS saw_billing,
    -- Step 7: Conversion
    MAX(CASE WHEN pageview_url = '/thank-you-for-your-order' THEN 1 ELSE 0 END) AS saw_thank_you_page
FROM website_pageviews
GROUP BY website_session_id;

-- Aggregating and calculating step-by-step drop-off rates

DROP TABLE IF EXISTS bi_conversion_funnel;

CREATE TABLE bi_conversion_funnel AS
WITH funnel_data AS (SELECT 
						MIN(CAST(CONCAT(YEAR(session_start_at), '-', MONTH(session_start_at), '-01') AS DATE)) AS month_start_date,
						COUNT(DISTINCT website_session_id) AS total_sessions,
						SUM(saw_homepage) AS to_home,
						SUM(saw_products) AS to_products,
						SUM(saw_product_page) AS to_product_page,
						SUM(saw_cart) AS to_cart,
						SUM(saw_shipping) AS to_shipping,
						SUM(saw_billing) AS to_billing,
						SUM(saw_thank_you_page) AS to_thank_you_page
					FROM website_performance
					GROUP BY YEAR(session_start_at), MONTH(session_start_at))

SELECT 
	month_start_date,
	-- Absolute volume
	total_sessions,
    to_home,
    to_products,
    to_product_page,
    to_cart,
    to_shipping,
    to_billing,
    to_thank_you_page,
    
    -- click-through rates CTR - identifying the leak
    
    -- homepage -> products
     ROUND(to_products / to_home * 100, 2) AS product_list_ctr,
     -- products -> product detail
     ROUND(to_product_page / to_products * 100, 2) AS product_page_ctr,
     -- product detail -> cart
     ROUND(to_cart / to_product_page * 100, 2) AS cart_ctr,
     -- cart -> shipping
	 ROUND(to_shipping / to_cart * 100, 2) AS shipping_ctr,
     -- shipping -> billing
	 ROUND(to_billing / to_shipping * 100, 2) AS billing_ctr,
     -- billing -> purchase
	 ROUND(to_thank_you_page / to_billing * 100, 2) AS thank_you_page_ctr
     
FROM funnel_data
ORDER BY month_start_date;


-- =============================================================================
-- 2. LANDING PAGE PERFORMANCE & SCALING
-- =============================================================================
/*
Strategy:
 - Analyzing traffic scaling over time rather than a strict A/B test, 
   as pages were launched sequentially.
 - Using First-Touch Attribution (MIN pageview_id) to map sessions to entry pages.
 - Objective: Assess how new landing pages (e.g., /lander-2) handled increased traffic volume 
   while maintaining conversion rates.
 - Performance: Optimizing query speed using indexed temporary tables.
*/

-- Pre-aggregating first pageviews 
DROP TEMPORARY TABLE IF EXISTS first_pageviews_table;

CREATE TEMPORARY TABLE first_pageviews_table AS 
SELECT 
	website_session_id,
	MIN(website_pageview_id) AS min_pageview_id
FROM website_pageviews
GROUP BY website_session_id;

ALTER TABLE first_pageviews_table ADD INDEX idx_min_pv_id (min_pageview_id);
ALTER TABLE first_pageviews_table ADD INDEX idx_session_id (website_session_id);
 
 
-- Trend Analysis
DROP TABLE IF EXISTS bi_landing_page_trends;

CREATE TABLE bi_landing_page_trends AS
WITH landing_page_trends AS (SELECT 
	MIN(CAST(CONCAT(YEAR(wp.created_at), '-', MONTH(wp.created_at), '-01') AS DATE)) AS month_start_date,
	wp.pageview_url AS landing_page,
    COUNT(DISTINCT wp.website_session_id) AS total_sessions,
	COUNT(DISTINCT o.order_id) AS total_orders,
	COALESCE(SUM(o.price_usd), 0) AS total_revenue
FROM first_pageviews_table fp
LEFT JOIN website_pageviews wp 
	ON fp.min_pageview_id = wp.website_pageview_id
LEFT JOIN orders o
	ON o.website_session_id = wp.website_session_id
WHERE wp.pageview_url IN ('/home','/lander-1','/lander-2','/lander-3','/lander-4','/lander-5')
GROUP BY YEAR(wp.created_at), MONTH(wp.created_at), wp.pageview_url)

SELECT 
	month_start_date,
	landing_page,
    total_sessions,
    total_orders,
    total_revenue, 
	ROUND(total_orders / NULLIF(total_sessions, 0) * 100, 2) AS conversion_rate_pct,
    ROUND(total_revenue / NULLIF(total_sessions, 0), 2) AS revenue_per_session,
    ROUND(total_revenue / NULLIF(total_orders, 0), 2) AS avg_order_value
FROM landing_page_trends
ORDER BY month_start_date, conversion_rate_pct DESC;



-- =============================================================================
-- 3. CHECKOUT OPTIMIZATION: BILLING PAGE A/B TEST
-- =============================================================================
/*
Strategy:
 - Comparing the original billing page vs. the new billing-2 version.
 - Methodology: Time-boxed Analysis.
   Restricting the dataset to the specific timeframe where both pages were active (Sep 2012 - Jan 2013).
 - Metric: Revenue per session is the primary KPI to determine the financial impact of the UX change.
*/

DROP TABLE IF EXISTS bi_billing_test_results;

CREATE TABLE bi_billing_test_results AS
WITH billing_sessions_unique AS (SELECT 
									website_session_id,
									pageview_url,
                                    MAX(created_at) AS billing_date_seen
								FROM website_pageviews
								WHERE pageview_url IN ('/billing', '/billing-2')
                                AND created_at BETWEEN '2012-09-01' AND '2013-01-31'
								GROUP BY website_session_id, pageview_url),

ab_test_billing_results AS (SELECT 
								b.pageview_url,
								COUNT(DISTINCT b.website_session_id) AS total_sessions,
								COUNT(DISTINCT o.order_id) AS total_orders,
								COALESCE(SUM(o.price_usd), 0) AS total_revenue
							FROM billing_sessions_unique b
							LEFT JOIN orders o 
								ON b.website_session_id = o.website_session_id
							GROUP BY b.pageview_url)

SELECT 
    pageview_url,
    total_sessions,
    total_orders,
    total_revenue,
    
    -- Impact analysis (conversion lift)
    ROUND(total_orders / NULLIF(total_sessions, 0) * 100, 2) AS conversion_rate_pct,
    
    -- Financial impact (revenue lift)
    ROUND(total_revenue / NULLIF(total_sessions, 0), 2) AS revenue_per_session,
    ROUND(total_revenue / NULLIF(total_orders, 0), 2) AS avg_order_value
FROM ab_test_billing_results
ORDER BY conversion_rate_pct DESC;