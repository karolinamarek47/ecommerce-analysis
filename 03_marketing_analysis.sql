/*
PROJECT: Maven Toys E-commerce Analysis
FILE: 03_marketing_analysis.sql
AUTHOR: Karolina Marek
 
DESCRIPTION:
This script evaluates the efficiency of marketing channels and traffic sources.

KEY ANALYSES:
 1. Marketing performance: Granular analysis of conversion and revenue by source, device, and ad creative.
 2. Traffic portfolio trends: Analyzing the shift between paid (ads) and free (organic/direct) traffic over time.
 3. Seasonality: identifying peak trading days to optimize marketing campaigns.
*/


-- =============================================================================
-- 1. MARKETING TABLE 
-- =============================================================================
/*
Strategy:
 - Constructing a multidimensional dataset to feed BI dashboards (Power BI/Tableau).
 - Key insights:
   * Device type: Identifying mobile vs. desktop performance gaps to guide UX improvements.
   * Ad content: Evaluating creative performance.
   * Revenue Per Session: Critical metric for setting Bid Caps (CPC) in ad platforms.
Note: Using Gross Revenue for marketing attribution as marketers are evaluated on generated sales, 
while returns are typically attributed to product quality or logistics.
*/

DROP TABLE IF EXISTS bi_marketing_overview;

CREATE TABLE bi_marketing_overview AS
WITH marketing_aggregated AS (SELECT 
	MIN(CAST(CONCAT(YEAR(s.created_at), '-', MONTH(s.created_at), '-01') AS DATE)) AS month_start_date,
    
    -- Dimensions for slicing data
	s.source,
    s.campaign,
    s.ad_content,
    s.device_type,
    
    -- Traffic volume
    COUNT(DISTINCT s.session_id) AS total_sessions,
    
    -- Sales volume
    COUNT(DISTINCT o.order_id) AS total_orders,
    
    -- Financials (gross)
    COALESCE(SUM(o.price_usd), 0) AS total_revenue,
    COALESCE(SUM(o.profit_gross), 0) AS total_profit
    
FROM website_sessions s
LEFT JOIN orders o 
ON o.website_session_id = s.session_id
GROUP BY 
	YEAR(s.created_at), MONTH(s.created_at), 
    s.source, 
    s.campaign,
    s.ad_content,
    s.device_type)
    
SELECT 
	month_start_date,
    source,
    campaign,
    ad_content,
    device_type,
    
    -- Absolute metrics
    total_sessions,
    total_orders,
    total_revenue,
    total_profit,
    
    -- Calculated KPIs
    
    -- Conversion Rate: The effectiveness of the funnel for this specific segment
    ROUND(total_orders / NULLIF(total_sessions, 0) * 100, 2) AS conversion_rate_pct,
    
    -- RPS: Indicates the maximum cost per click (CPC) we can afford to break even.
    -- E.g., if RPS is $3.00, bidding $4.00 for a click leads to a loss.
    ROUND(total_revenue / NULLIF(total_sessions, 0), 2)  AS revenue_per_session
    
FROM marketing_aggregated
ORDER BY month_start_date;


-- =============================================================================
-- 2. TRAFFIC SOURCE TRENDS 
-- =============================================================================
/*
Strategy:
 - Pivoting data from rows to columns to visualize the marketing mix evolution.
 - Objective: 
   1. Monitor dependency on paid channels.
   2. Track the growth of brand equity.
   3. Analyze the impact of SEO efforts over time.
*/

DROP TABLE IF EXISTS bi_traffic_trends;

CREATE TABLE bi_traffic_trends AS
WITH traffic_data AS (SELECT 
	MIN(CAST(CONCAT(YEAR(created_at), '-', MONTH(created_at), '-01') AS DATE)) AS month_start_date,
    
    -- Paid channels
    COUNT(DISTINCT CASE WHEN channel_group = 'paid_search_google' THEN session_id END) AS paid_google_traffic,
    COUNT(DISTINCT CASE WHEN channel_group = 'paid_search_bing' THEN session_id END) AS paid_bing_traffic,
    COUNT(DISTINCT CASE WHEN channel_group = 'paid_search_socialbook' THEN session_id END) AS paid_socialbook_traffic,
	
    -- Total paid bucket
    COUNT(DISTINCT CASE WHEN channel_group IN ('paid_search_google','paid_search_bing','paid_search_socialbook') THEN session_id END) AS paid_traffic,
    
    -- Organic channels (seo efforts)
    COUNT(DISTINCT CASE WHEN channel_group = 'organic_search_google' THEN session_id END) AS organic_google_traffic,
    COUNT(DISTINCT CASE WHEN channel_group = 'organic_search_bing' THEN session_id END) AS organic_bing_traffic,
    COUNT(DISTINCT CASE WHEN channel_group = 'organic_search_socialbook' THEN session_id END) AS organic_socialbook_traffic,
   
    -- Total organic bucket
    COUNT(DISTINCT CASE WHEN channel_group IN ('organic_search_google','organic_search_bing','organic_search_socialbook') THEN session_id END) AS organic_traffic,
    
    -- Direct (brand awareness, loyal users)
    COUNT(DISTINCT CASE WHEN channel_group = 'direct_type_in' THEN session_id END) AS direct_traffic,
    
    -- Other/unknown
    COUNT(DISTINCT CASE WHEN channel_group = 'other' THEN session_id END) AS other_traffic,
    
    -- Total volume
    COUNT(DISTINCT session_id) AS total_sessions
FROM website_sessions
GROUP BY YEAR(created_at), MONTH(created_at))

SELECT 
	month_start_date,
    paid_google_traffic,
    paid_bing_traffic,
    paid_socialbook_traffic,
    paid_traffic,
    organic_google_traffic,
    organic_bing_traffic,
    organic_socialbook_traffic,
    organic_traffic,
    direct_traffic,
    other_traffic,
    total_sessions,
    
    -- SHARE ANALYSIS
    -- Are we diversifying our traffic sources or relying too heavily on paid ads?
    ROUND(paid_traffic / NULLIF(total_sessions, 0) * 100, 2) AS paid_traffic_share_pct,
    ROUND((organic_traffic + direct_traffic) / NULLIF(total_sessions, 0) * 100, 2) AS organic_traffic_share_pct
    
FROM traffic_data
ORDER BY month_start_date;

-- =============================================================================
-- 3. DAY OF WEEK SEASONALITY
-- =============================================================================
/*
 Identifying purchasing patterns to optimize marketing campaigns (e.g., email blasts).
*/

DROP TABLE IF EXISTS bi_sales_seasonality;

CREATE TABLE bi_sales_seasonality AS
SELECT 
	CAST(CONCAT(YEAR(o.created_at), '-', MONTH(o.created_at), '-01') AS DATE) AS date,
    s.source,
	WEEKDAY(o.created_at) AS day_number,
	CASE 
		WHEN WEEKDAY(o.created_at) = 0 THEN 'monday'
        WHEN WEEKDAY(o.created_at) = 1 THEN 'tuesday'
        WHEN WEEKDAY(o.created_at) = 2 THEN 'wednesday'
        WHEN WEEKDAY(o.created_at) = 3 THEN 'thursday'
        WHEN WEEKDAY(o.created_at) = 4 THEN 'friday'
        WHEN WEEKDAY(o.created_at) = 5 THEN 'saturday'
        WHEN WEEKDAY(o.created_at) = 6 THEN 'sunday'
	END AS day_of_week,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(AVG(o.price_usd), 2) AS avg_order_value
FROM orders o
LEFT JOIN website_sessions s 
    ON o.website_session_id = s.session_id
GROUP BY 1, 2, 3, 4
ORDER BY 1, 3;

    