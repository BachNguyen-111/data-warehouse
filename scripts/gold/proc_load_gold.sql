/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
Script Purpose:
    This stored procedure loads the Gold star schema from the Silver layer.
    Unlike Bronze and Silver, the dimensions are NOT truncated: Gold keeps
    history and its surrogate keys stay the same from one load to the next.

    Actions Performed:
        1. gold.dim_date      -> adds any calendar days that are missing
        2. gold.dim_customers -> SCD Type 1: new customers are inserted,
                                 changed customers are overwritten (MERGE)
        3. gold.dim_products  -> SCD Type 2:
             - first load : back-fills the full product history from Silver
             - later loads: compares each product's current row in Silver with
                            its current version in Gold; if anything changed,
                            the old version is closed and a new one is opened
        4. gold.fact_sales    -> truncated and reloaded, linking every sale to
                                 the product version valid on its order date

    Everything runs in one transaction: if any step fails, nothing is changed.

Parameters:
    @load_date DATE (optional) - the business date of the load. Defaults to
        today. New product versions start on this date. Only pass a date to
        test (e.g. simulate tomorrow's load); never pass a date earlier than
        the last load.

Usage Example:
    EXEC gold.load_gold;
    EXEC gold.load_gold @load_date = '2026-11-01';
===============================================================================
*/

CREATE OR ALTER PROCEDURE gold.load_gold
    @load_date DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;
    DECLARE @rows INT, @cal_start DATE, @cal_end DATE;
    DECLARE @customer_changes TABLE (merge_action NVARCHAR(10));

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        SET @load_date = COALESCE(@load_date, CAST(GETDATE() AS DATE));

        PRINT '================================================';
        PRINT 'Loading Gold Layer (load date: ' + CONVERT(NVARCHAR, @load_date, 23) + ')';
        PRINT '================================================';

        BEGIN TRANSACTION;

        -- =====================================================================
        -- 1. gold.dim_date: add missing days (never deletes)
        -- =====================================================================
        SET @start_time = GETDATE();
        PRINT '>> Loading: gold.dim_date';

        -- 'Unknown' member for sales with a missing date
        IF NOT EXISTS (SELECT 1 FROM gold.dim_date WHERE date_key = -1)
            INSERT INTO gold.dim_date (date_key, day_name, day_name_short, day_type, month_name,
                                       month_name_short, quarter_name, year_month)
            VALUES (-1, 'n/a', 'n/a', 'n/a', 'n/a', 'n/a', 'n/a', 'n/a');

        -- Calendar must cover Jan 1 of the first sales year to Dec 31 of the last
        SELECT
            @cal_start = DATEFROMPARTS(YEAR(MIN(d)), 1, 1),
            @cal_end   = DATEFROMPARTS(YEAR(MAX(d)), 12, 31)
        FROM silver.crm_sales_details
        CROSS APPLY (VALUES (sls_order_dt), (sls_ship_dt), (sls_due_dt)) AS v(d);

        IF @cal_start IS NOT NULL
        BEGIN
            ;WITH digits AS (
                SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS t(n)
            ),
            numbers AS ( -- 0 to 99,999
                SELECT a.n + b.n*10 + c.n*100 + d.n*1000 + e.n*10000 AS n
                FROM digits a CROSS JOIN digits b CROSS JOIN digits c
                CROSS JOIN digits d CROSS JOIN digits e
            ),
            calendar AS (
                SELECT DATEADD(DAY, n, @cal_start) AS full_date
                FROM numbers
                WHERE n <= DATEDIFF(DAY, @cal_start, @cal_end)
            )
            INSERT INTO gold.dim_date (
                date_key, full_date, day_of_month, day_of_year, day_of_week, day_name,
                day_name_short, day_type, week_of_year, month_number, month_name,
                month_name_short, quarter_number, quarter_name, year, year_month,
                first_day_of_month, last_day_of_month
            )
            SELECT
                YEAR(full_date) * 10000 + MONTH(full_date) * 100 + DAY(full_date),
                full_date,
                DAY(full_date),
                DATEPART(DAYOFYEAR, full_date),
                (DATEDIFF(DAY, '19000101', full_date) % 7) + 1,   -- 1 = Monday (independent of server settings)
                DATENAME(WEEKDAY, full_date),
                LEFT(DATENAME(WEEKDAY, full_date), 3),
                CASE WHEN (DATEDIFF(DAY, '19000101', full_date) % 7) + 1 IN (6, 7) THEN 'Weekend' ELSE 'Weekday' END,
                DATEPART(ISO_WEEK, full_date),
                MONTH(full_date),
                DATENAME(MONTH, full_date),
                LEFT(DATENAME(MONTH, full_date), 3),
                DATEPART(QUARTER, full_date),
                'Q' + CAST(DATEPART(QUARTER, full_date) AS NVARCHAR(1)),
                YEAR(full_date),
                CONVERT(NVARCHAR(7), full_date, 120),
                DATEFROMPARTS(YEAR(full_date), MONTH(full_date), 1),
                EOMONTH(full_date)
            FROM calendar c
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date dd WHERE dd.full_date = c.full_date);
            SET @rows = @@ROWCOUNT;
            PRINT '   Days added: ' + CAST(@rows AS NVARCHAR);
        END

        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- =====================================================================
        -- 2. gold.dim_customers: SCD Type 1 (insert new, overwrite changed)
        -- =====================================================================
        SET @start_time = GETDATE();
        PRINT '>> Loading: gold.dim_customers (SCD Type 1)';

        WITH src AS (
            SELECT
                ci.cst_id             AS customer_id,
                ci.cst_key            AS customer_number,
                ci.cst_firstname      AS first_name,
                ci.cst_lastname       AS last_name,
                la.cntry              AS country,
                ci.cst_marital_status AS marital_status,
                CASE
                    WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr -- CRM is the primary source for gender
                    ELSE COALESCE(ca.gen, 'n/a')               -- Fallback to ERP data
                END                   AS gender,
                ca.bdate              AS birthdate,
                ci.cst_create_date    AS create_date
            FROM silver.crm_cust_info ci
            LEFT JOIN silver.erp_cust_az12 ca
                ON ci.cst_key = ca.cid
            LEFT JOIN silver.erp_loc_a101 la
                ON ci.cst_key = la.cid
        )
        MERGE gold.dim_customers AS tgt
        USING src
            ON tgt.customer_id = src.customer_id
        -- "EXISTS (... EXCEPT ...)" is true when at least one column differs.
        -- Unlike "<>", it also treats NULL vs value as a change.
        WHEN MATCHED AND EXISTS (
                SELECT src.customer_number, src.first_name, src.last_name, src.country,
                       src.marital_status, src.gender, src.birthdate, src.create_date
                EXCEPT
                SELECT tgt.customer_number, tgt.first_name, tgt.last_name, tgt.country,
                       tgt.marital_status, tgt.gender, tgt.birthdate, tgt.create_date
            )
            THEN UPDATE SET
                tgt.customer_number = src.customer_number,
                tgt.first_name      = src.first_name,
                tgt.last_name       = src.last_name,
                tgt.country         = src.country,
                tgt.marital_status  = src.marital_status,
                tgt.gender          = src.gender,
                tgt.birthdate       = src.birthdate,
                tgt.create_date     = src.create_date,
                tgt.dwh_update_date = GETDATE()
        WHEN NOT MATCHED BY TARGET
            THEN INSERT (customer_id, customer_number, first_name, last_name, country,
                         marital_status, gender, birthdate, create_date)
                 VALUES (src.customer_id, src.customer_number, src.first_name, src.last_name, src.country,
                         src.marital_status, src.gender, src.birthdate, src.create_date)
        OUTPUT $action INTO @customer_changes;

        PRINT '   Customers inserted: ' + CAST((SELECT COUNT(*) FROM @customer_changes WHERE merge_action = 'INSERT') AS NVARCHAR);
        PRINT '   Customers updated : ' + CAST((SELECT COUNT(*) FROM @customer_changes WHERE merge_action = 'UPDATE') AS NVARCHAR);

        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- =====================================================================
        -- 3. gold.dim_products: SCD Type 2 (keep every version)
        -- =====================================================================
        SET @start_time = GETDATE();
        PRINT '>> Loading: gold.dim_products (SCD Type 2)';

        IF NOT EXISTS (SELECT 1 FROM gold.dim_products)
        BEGIN
            -- -----------------------------------------------------------------
            -- 3a. FIRST LOAD: back-fill the history the source already has.
            -- The first version's valid_from is 1900-01-01 because some sales
            -- happened before the product's first recorded start date.
            -- -----------------------------------------------------------------
            INSERT INTO gold.dim_products (
                product_id, product_number, product_name, category_id, category, subcategory,
                maintenance, cost, product_line, start_date, valid_from, valid_to, is_current, version_number
            )
            SELECT
                pn.prd_id,
                pn.prd_key,
                pn.prd_nm,
                pn.cat_id,
                pc.cat,
                pc.subcat,
                pc.maintenance,
                pn.prd_cost,
                pn.prd_line,
                pn.prd_start_dt,
                CASE
                    WHEN ROW_NUMBER() OVER (PARTITION BY pn.prd_key ORDER BY pn.prd_start_dt) = 1
                        THEN CAST('1900-01-01' AS DATE)
                    ELSE pn.prd_start_dt
                END,
                COALESCE(pn.prd_end_dt, CAST('9999-12-31' AS DATE)),
                CASE WHEN pn.prd_end_dt IS NULL THEN 1 ELSE 0 END,
                ROW_NUMBER() OVER (PARTITION BY pn.prd_key ORDER BY pn.prd_start_dt)
            FROM silver.crm_prd_info pn
            LEFT JOIN silver.erp_px_cat_g1v2 pc
                ON pn.cat_id = pc.id
            ORDER BY pn.prd_start_dt, pn.prd_key; -- keys are assigned in this order
            SET @rows = @@ROWCOUNT;
            PRINT '   First load - product versions back-filled: ' + CAST(@rows AS NVARCHAR);
        END
        ELSE
        BEGIN
            -- -----------------------------------------------------------------
            -- 3b. LATER LOADS: detect changes ourselves
            -- -----------------------------------------------------------------
            -- Current state of each product in the source
            DROP TABLE IF EXISTS #src_products;
            SELECT
                pn.prd_id       AS product_id,
                pn.prd_key      AS product_number,
                pn.prd_nm       AS product_name,
                pn.cat_id       AS category_id,
                pc.cat          AS category,
                pc.subcat       AS subcategory,
                pc.maintenance  AS maintenance,
                pn.prd_cost     AS cost,
                pn.prd_line     AS product_line,
                pn.prd_start_dt AS start_date
            INTO #src_products
            FROM silver.crm_prd_info pn
            LEFT JOIN silver.erp_px_cat_g1v2 pc
                ON pn.cat_id = pc.id
            WHERE pn.prd_end_dt IS NULL;

            -- Products whose current version differs from the source
            -- (tracked columns: name, category, maintenance, cost, product line)
            DROP TABLE IF EXISTS #changed_products;
            SELECT d.product_key, d.valid_from
            INTO #changed_products
            FROM gold.dim_products d
            JOIN #src_products s
                ON s.product_number = d.product_number
            WHERE d.is_current = 1
              AND EXISTS (
                    SELECT s.product_name, s.category_id, s.category, s.subcategory,
                           s.maintenance, s.cost, s.product_line
                    EXCEPT
                    SELECT d.product_name, d.category_id, d.category, d.subcategory,
                           d.maintenance, d.cost, d.product_line
                  );
            PRINT '   Products changed: ' + CAST(@@ROWCOUNT AS NVARCHAR);

            -- Step 1: a version that only started today is corrected in place
            --         (two changes on the same day = one version for that day)
            UPDATE d
            SET d.product_id      = s.product_id,
                d.product_name    = s.product_name,
                d.category_id     = s.category_id,
                d.category        = s.category,
                d.subcategory     = s.subcategory,
                d.maintenance     = s.maintenance,
                d.cost            = s.cost,
                d.product_line    = s.product_line,
                d.start_date      = s.start_date,
                d.dwh_update_date = GETDATE()
            FROM gold.dim_products d
            JOIN #changed_products c ON c.product_key = d.product_key
            JOIN #src_products s     ON s.product_number = d.product_number
            WHERE c.valid_from = @load_date;

            -- Step 2: close the old version (it ends the day before the load date)
            UPDATE d
            SET d.valid_to        = DATEADD(DAY, -1, @load_date),
                d.is_current      = 0,
                d.dwh_update_date = GETDATE()
            FROM gold.dim_products d
            JOIN #changed_products c ON c.product_key = d.product_key
            WHERE c.valid_from < @load_date;
            PRINT '   Versions closed : ' + CAST(@@ROWCOUNT AS NVARCHAR);

            -- Step 3: open a new version for every product without a current one
            --         (= products closed in step 2 + brand-new products)
            INSERT INTO gold.dim_products (
                product_id, product_number, product_name, category_id, category, subcategory,
                maintenance, cost, product_line, start_date, valid_from, valid_to, is_current, version_number
            )
            SELECT
                s.product_id,
                s.product_number,
                s.product_name,
                s.category_id,
                s.category,
                s.subcategory,
                s.maintenance,
                s.cost,
                s.product_line,
                s.start_date,
                CASE WHEN prev.max_version IS NULL
                     THEN CAST('1900-01-01' AS DATE) -- brand-new product: covers all its sales
                     ELSE @load_date                 -- changed product: new version starts today
                END,
                CAST('9999-12-31' AS DATE),
                1,
                COALESCE(prev.max_version, 0) + 1
            FROM #src_products s
            LEFT JOIN (
                SELECT product_number, MAX(version_number) AS max_version
                FROM gold.dim_products
                GROUP BY product_number
            ) prev
                ON prev.product_number = s.product_number
            WHERE NOT EXISTS (
                SELECT 1 FROM gold.dim_products d
                WHERE d.product_number = s.product_number
                  AND d.is_current = 1
            );
            PRINT '   Versions opened : ' + CAST(@@ROWCOUNT AS NVARCHAR);

            DROP TABLE IF EXISTS #src_products;
            DROP TABLE IF EXISTS #changed_products;
        END

        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- =====================================================================
        -- 4. gold.fact_sales: full reload
        -- =====================================================================
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.fact_sales';
        TRUNCATE TABLE gold.fact_sales;

        PRINT '>> Inserting Data Into: gold.fact_sales';
        INSERT INTO gold.fact_sales (
            order_number, product_key, customer_key, order_date_key, shipping_date_key, due_date_key,
            order_date, shipping_date, due_date, sales_amount, quantity, price
        )
        SELECT
            sd.sls_ord_num,
            pr.product_key,
            cu.customer_key,
            -- Date keys (YYYYMMDD); missing dates -> -1 (Unknown)
            COALESCE(YEAR(sd.sls_order_dt) * 10000 + MONTH(sd.sls_order_dt) * 100 + DAY(sd.sls_order_dt), -1),
            COALESCE(YEAR(sd.sls_ship_dt)  * 10000 + MONTH(sd.sls_ship_dt)  * 100 + DAY(sd.sls_ship_dt),  -1),
            COALESCE(YEAR(sd.sls_due_dt)   * 10000 + MONTH(sd.sls_due_dt)   * 100 + DAY(sd.sls_due_dt),   -1),
            sd.sls_order_dt,
            sd.sls_ship_dt,
            sd.sls_due_dt,
            sd.sls_sales,
            sd.sls_quantity,
            sd.sls_price
        FROM silver.crm_sales_details sd
        LEFT JOIN gold.dim_products pr
            ON  sd.sls_prd_key = pr.product_number
            AND (
                    -- The product version that was valid on the order date
                    sd.sls_order_dt BETWEEN pr.valid_from AND pr.valid_to
                    -- Unknown order date -> current version
                 OR (sd.sls_order_dt IS NULL AND pr.is_current = 1)
                )
        LEFT JOIN gold.dim_customers cu
            ON sd.sls_cust_id = cu.customer_id;
        SET @rows = @@ROWCOUNT;
        PRINT '   Sales loaded: ' + CAST(@rows AS NVARCHAR);

        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        COMMIT TRANSACTION;

        SET @batch_end_time = GETDATE();
        PRINT '==========================================';
        PRINT 'Loading Gold Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; -- undo everything from this run
        PRINT '==========================================';
        PRINT 'ERROR OCCURRED DURING LOADING GOLD LAYER (all changes rolled back)';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State  : ' + CAST(ERROR_STATE() AS NVARCHAR);
        PRINT '==========================================';
        THROW; -- re-raise so the caller sees the load failed
    END CATCH
END
