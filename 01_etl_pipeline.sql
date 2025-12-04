/*
PROJECT: Maven Toys E-commerce Analysis
FILE: 01_etl_pipeline.sql
AUTHOR: Karolina Marek

DESCRIPTION: 
This script executes the end-to-end ETL pipeline.
  
KEY ACTIONS:
  1. Schema design: Defines an optimized database schema with appropriate data types (INT, DECIMAL, DATETIME).
  2. Data cleaning: Handles NULL values, parses raw text dates, and standardizes currency formats.
  3. Normalization: Transforms raw string data into a structured relational model.
  4. Performance tuning: Implements indexing strategies (primary keys, foreign keys) to enhance query speed.
  5. Feature engineering: Pre-calculates key metrics (e.g., gross profit) during the data loading phase.
*/


-- table: products -- 
DROP TABLE IF EXISTS products;

CREATE TABLE products (
    product_id BIGINT UNSIGNED PRIMARY KEY,
    created_at DATETIME,
    product_name VARCHAR(100) 
);

INSERT INTO products
SELECT 
    CAST(product_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    product_name
FROM raw_products;

-- table: orders --

DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id BIGINT UNSIGNED PRIMARY KEY,
    created_at DATETIME,
    website_session_id BIGINT UNSIGNED,
    user_id BIGINT UNSIGNED,
    primary_product_id SMALLINT UNSIGNED, 
    items_purchased INT UNSIGNED,
    price_usd DECIMAL(10,2), 
    cogs_usd DECIMAL(10,2),  
    profit_gross DECIMAL(10,2), 
    
    -- INDEXES
    INDEX idx_created_at (created_at),          
    INDEX idx_session_id (website_session_id), 
    INDEX idx_product_id (primary_product_id)   
);

INSERT INTO orders
SELECT 
    CAST(order_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    CAST(website_session_id AS UNSIGNED),
    CAST(user_id AS UNSIGNED),
    CAST(primary_product_id AS UNSIGNED),
    CAST(items_purchased AS UNSIGNED),
    CAST(price_usd AS DECIMAL(10,2)),
    CAST(cogs_usd AS DECIMAL(10,2)),
    -- calculated profit gross
    (CAST(price_usd AS DECIMAL(10,2)) - CAST(cogs_usd AS DECIMAL(10,2)))
FROM raw_orders;

-- table: order_items --
DROP TABLE IF EXISTS order_items;

CREATE TABLE order_items (
    order_item_id BIGINT UNSIGNED PRIMARY KEY,
    created_at DATETIME,
    order_id BIGINT UNSIGNED,
    product_id BIGINT UNSIGNED,
    is_primary_item TINYINT, -- 1 = primary product, 0 = additional product (cross-sell)
    price_usd DECIMAL(10,2),
    cogs_usd DECIMAL(10,2),
    
    -- INDEXES
    INDEX idx_order_id (order_id),     
    INDEX idx_product_id (product_id)  
);


INSERT INTO order_items
SELECT 
    CAST(order_item_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    CAST(order_id AS UNSIGNED),
    CAST(product_id AS UNSIGNED),
    CAST(is_primary_item AS UNSIGNED),
    CAST(price_usd AS DECIMAL(10,2)),
    CAST(cogs_usd AS DECIMAL(10,2))
FROM raw_order_items;

-- table: order_item_refunds --
DROP TABLE IF EXISTS order_item_refunds;

CREATE TABLE order_item_refunds (
    refund_id BIGINT UNSIGNED PRIMARY KEY,
    order_item_id BIGINT UNSIGNED,
    order_id BIGINT UNSIGNED,
    refund_date DATETIME,
    refund_amount DECIMAL(10,2),
    
    -- INDEXES
    INDEX idx_order_id (order_id), 
    INDEX idx_order_item_id (order_item_id) 
);

INSERT INTO order_item_refunds
SELECT 
    CAST(order_item_refund_id AS UNSIGNED),
    CAST(order_item_id AS UNSIGNED),
    CAST(order_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    CAST(refund_amount_usd AS DECIMAL(10,2))
FROM raw_order_item_refunds;

-- table: website sessions -- 
DROP TABLE IF EXISTS website_sessions;



CREATE TABLE website_sessions (
    session_id BIGINT UNSIGNED PRIMARY KEY,
    user_id BIGINT UNSIGNED,
    created_at DATETIME,
    channel_group VARCHAR(50), 
    source VARCHAR(50),        
    campaign VARCHAR(50),      
    ad_content VARCHAR(50),    
    device_type VARCHAR(20),   
    is_repeat_session TINYINT, 
    
    -- INDEXES
    INDEX idx_user_id (user_id),       
    INDEX idx_created_at (created_at)  
);

INSERT INTO website_sessions
SELECT 
    CAST(website_session_id AS UNSIGNED),
    CAST(user_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    
    -- Channel Grouping
    CASE 
        WHEN utm_source = 'gsearch' THEN 'paid_search_google'
        WHEN utm_source = 'bsearch' THEN 'paid_search_bing'
        WHEN utm_source = 'socialbook' THEN 'paid_search_socialbook'
        WHEN utm_source IS NULL AND http_referer LIKE '%gsearch.com' THEN 'organic_search_google'
        WHEN utm_source IS NULL AND http_referer LIKE '%bsearch.com' THEN 'organic_search_bing'
        WHEN utm_source IS NULL AND http_referer LIKE '%socialbook.com' THEN 'organic_search_socialbook'
        WHEN utm_source IS NULL AND http_referer IS NULL THEN 'direct_type_in'
        ELSE 'other'
    END,

    -- Source
    CASE 
        WHEN utm_source IS NOT NULL THEN utm_source 
        WHEN http_referer LIKE '%gsearch%' THEN 'gsearch'
        WHEN http_referer LIKE '%bsearch%' THEN 'bsearch'
        WHEN http_referer LIKE '%socialbook%' THEN 'socialbook'
        ELSE 'other'
    END,

    -- Campaign
    COALESCE(utm_campaign, 'organic_non_paid'),
    
    -- Ad Content
    CASE 
		WHEN utm_content IS NULL THEN 'organic'
		WHEN utm_content = 'n/a' THEN 'organic'
		ELSE utm_content 
	END AS ad_content,
    
    device_type, 
    -- Flag on returning customer
    CASE WHEN is_repeat_session = '1' THEN 1 ELSE 0 END

FROM raw_website_sessions;

-- table: website pageviews --
DROP TABLE IF EXISTS website_pageviews;

CREATE TABLE website_pageviews (
    website_pageview_id BIGINT UNSIGNED PRIMARY KEY, 
    created_at DATETIME,
    website_session_id BIGINT UNSIGNED,
    pageview_url VARCHAR(255), 
    -- indexes
    INDEX idx_session_id (website_session_id),
    INDEX idx_pageview_url (pageview_url));

INSERT INTO website_pageviews 
SELECT
	CAST(website_pageview_id AS UNSIGNED),
    STR_TO_DATE(created_at, '%Y-%m-%d %H:%i:%s'),
    CAST(website_session_id AS UNSIGNED),
	pageview_url
FROM raw_website_pageviews;