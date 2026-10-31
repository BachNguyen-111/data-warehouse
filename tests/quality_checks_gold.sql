/*
===============================================================================
Quality Checks
===============================================================================
Script Purpose:
    This script performs quality checks to validate the integrity, consistency, 
    and accuracy of the Gold Layer. These checks ensure:
    - Uniqueness of surrogate keys in dimension tables.
    - Referential integrity between fact and dimension tables.
    - Validation of relationships in the data model for analytical purposes.

Usage Notes:
    - Run after: EXEC gold.load_gold;
    - Investigate and resolve any discrepancies found during the checks.
===============================================================================
*/

-- ====================================================================
-- Checking 'gold.dim_customers'
-- ====================================================================
-- Check for Uniqueness of Customer Key in gold.dim_customers
-- Expectation: No results 
SELECT 
    customer_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1;

-- ====================================================================
-- Checking 'gold.product_key'
-- ====================================================================
-- Check for Uniqueness of Product Key in gold.dim_products
-- Expectation: No results 
SELECT 
    product_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_products
GROUP BY product_key
HAVING COUNT(*) > 1;

-- SCD Type 2 checks on gold.dim_products
-- Each product must have exactly one current version
-- Expectation: No results
SELECT 
    product_number,
    SUM(is_current) AS current_versions
FROM gold.dim_products
GROUP BY product_number
HAVING SUM(is_current) <> 1;

-- Versions of the same product must not overlap in time
-- Expectation: No results
SELECT a.product_number, a.product_key, b.product_key AS overlapping_key
FROM gold.dim_products a
JOIN gold.dim_products b
    ON  a.product_number = b.product_number
    AND a.product_key < b.product_key
    AND a.valid_from <= b.valid_to
    AND b.valid_from <= a.valid_to;

-- Versions must be valid periods (start before end)
-- Expectation: No results
SELECT product_key, product_number, valid_from, valid_to
FROM gold.dim_products
WHERE valid_from > valid_to;

-- ====================================================================
-- Checking 'gold.fact_sales'
-- ====================================================================
-- Every sale must match exactly one product version (no lost or duplicated rows)
-- Expectation: both counts are equal
SELECT
    (SELECT COUNT(*) FROM silver.crm_sales_details) AS silver_rows,
    (SELECT COUNT(*) FROM gold.fact_sales)          AS gold_rows;

-- Check the data model connectivity between fact and dimensions
SELECT * 
FROM gold.fact_sales f
LEFT JOIN gold.dim_customers c
ON c.customer_key = f.customer_key
LEFT JOIN gold.dim_products p
ON p.product_key = f.product_key
WHERE p.product_key IS NULL OR c.customer_key IS NULL;

-- ====================================================================
-- Checking 'gold.dim_date'
-- ====================================================================
-- Check for Uniqueness of Date Key in gold.dim_date
-- Expectation: No results
SELECT 
    date_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_date
GROUP BY date_key
HAVING COUNT(*) > 1;

-- Check for gaps: every day between first and last date must exist
-- Expectation: day_count = expected_days
SELECT
    COUNT(*)                                          AS day_count,
    DATEDIFF(DAY, MIN(full_date), MAX(full_date)) + 1 AS expected_days
FROM gold.dim_date
WHERE date_key <> -1;

-- Check that every date key in the fact exists in gold.dim_date
-- Expectation: No results
SELECT f.order_number, f.order_date_key, f.shipping_date_key, f.due_date_key
FROM gold.fact_sales f
LEFT JOIN gold.dim_date od ON od.date_key = f.order_date_key
LEFT JOIN gold.dim_date sd ON sd.date_key = f.shipping_date_key
LEFT JOIN gold.dim_date dd ON dd.date_key = f.due_date_key
WHERE od.date_key IS NULL OR sd.date_key IS NULL OR dd.date_key IS NULL;

-- Info: how many sales point to the Unknown date member
-- Expectation: a small number (rows with invalid order dates in the source)
SELECT COUNT(*) AS unknown_order_dates
FROM gold.fact_sales
WHERE order_date_key = -1;
