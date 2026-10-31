/*
===============================================================================
Test: SCD Type 2 change detection on gold.dim_products
===============================================================================
Script Purpose:
    Shows the warehouse detecting a change by itself. It simulates a price
    change in the source, runs the Gold load as of tomorrow, and shows that the
    old version was closed and a new version was opened.

    Run the steps one at a time and compare the results.

Requirements:
    Gold must already be loaded (EXEC gold.load_gold;).

WARNING:
    This test changes data. Step 6 shows how to reset everything afterwards.
===============================================================================
*/

-- Step 1: Product history BEFORE the change
-- Expectation: 3 versions, only version 3 has is_current = 1
SELECT product_key, product_number, cost, valid_from, valid_to, is_current, version_number
FROM gold.dim_products
WHERE product_number = 'HL-U509-R'
ORDER BY version_number;

-- Step 2: Simulate a price change in the source (+10 on the current cost)
UPDATE silver.crm_prd_info
SET prd_cost = prd_cost + 10
WHERE prd_key = 'HL-U509-R'
  AND prd_end_dt IS NULL;

-- Step 3: Run the Gold load as of tomorrow
-- Expectation (Messages tab): Products changed: 1, Versions closed: 1, Versions opened: 1
DECLARE @tomorrow DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE));
EXEC gold.load_gold @load_date = @tomorrow;

-- Step 4: Product history AFTER the change
-- Expectation: 4 versions
--   version 3 now ends today (valid_to = today, is_current = 0)
--   version 4 has the new cost, starts tomorrow and is the current version
SELECT product_key, product_number, cost, valid_from, valid_to, is_current, version_number
FROM gold.dim_products
WHERE product_number = 'HL-U509-R'
ORDER BY version_number;

-- Step 5: Old sales still point to the old versions
-- Expectation: each sale shows the cost that was valid on its order date
SELECT TOP 10
    f.order_number, f.order_date, p.version_number, p.cost, p.valid_from, p.valid_to
FROM gold.fact_sales f
JOIN gold.dim_products p
    ON p.product_key = f.product_key
WHERE p.product_number = 'HL-U509-R'
ORDER BY f.order_date DESC;

-- Step 6: Reset (removes the test version)
--   1. Reload Silver from Bronze:      EXEC silver.load_silver;
--   2. Recreate the Gold tables:       run scripts/gold/ddl_gold.sql
--   3. Load Gold again:                EXEC gold.load_gold;
