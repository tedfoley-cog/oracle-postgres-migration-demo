-- =============================================================================
-- pg_cron Job Definitions — Migrated from Oracle DBMS_SCHEDULER
-- Migration notes:
--   DBMS_SCHEDULER.CREATE_JOB   → pg_cron.schedule()
--   DBMS_MVIEW.REFRESH('X','C') → REFRESH MATERIALIZED VIEW CONCURRENTLY X
--   PL/SQL anonymous block      → SQL command string
--   Calendar expressions        → cron syntax (min hour day month weekday)
--   Job chains                  → Sequential SQL in a single cron job
--   TRUNC(SYSDATE+1) + 22/24   → cron: '0 22 * * *'
--   FREQ=WEEKLY; BYDAY=SUN     → cron: '0 6 * * 0'
--   FREQ=MONTHLY; BYMONTHDAY=1 → cron: '0 3 1 * *'
-- =============================================================================

-- Requires: CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Note: pg_cron must be loaded via shared_preload_libraries in postgresql.conf
-- and the extension created in the target database.

-- 1. Nightly inventory valuation refresh — 10 PM daily
-- Oracle: JOB_REFRESH_INV_VALUATION
SELECT cron.schedule(
    'job_refresh_inv_valuation',
    '0 22 * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_inventory_valuation'
);

-- 2. Weekly supplier performance refresh — Sunday 6 AM
-- Oracle: JOB_REFRESH_SUPPLIER_PERF
SELECT cron.schedule(
    'job_refresh_supplier_perf',
    '0 6 * * 0',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_supplier_performance'
);

-- 3. Monthly warranty cost analysis refresh — 1st of month, 3 AM
-- Oracle: JOB_REFRESH_WARRANTY_COST
SELECT cron.schedule(
    'job_refresh_warranty_cost',
    '0 3 1 * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_warranty_cost_analysis'
);

-- 4. Daily production backlog refresh — 5 AM daily
-- Oracle: JOB_REFRESH_PROD_BACKLOG
SELECT cron.schedule(
    'job_refresh_prod_backlog',
    '0 5 * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_production_backlog'
);

-- 5. Nightly warranty claims batch processing — 11 PM daily
-- Oracle: JOB_PROCESS_WARRANTY_CLAIMS
SELECT cron.schedule(
    'job_process_warranty_claims',
    '0 23 * * *',
    'SELECT mfg.fn_process_batch_claims(CURRENT_TIMESTAMP)'
);

-- 6. Nightly reorder point check — 9 PM daily
-- Oracle: JOB_CHECK_REORDER_POINTS
SELECT cron.schedule(
    'job_check_reorder_points',
    '0 21 * * *',
    'SELECT mfg.fn_check_reorder_points()'
);

-- =============================================================================
-- Oracle CHAIN_NIGHTLY_BATCH equivalent
-- The Oracle job chain ran 4 steps sequentially:
--   1. Refresh inventory valuation
--   2. Check reorder points
--   3. Process warranty claims
--   4. Refresh production backlog
--
-- In PostgreSQL, this is implemented as a single pg_cron job that executes
-- all steps sequentially in one transaction. Scheduled at 10 PM nightly
-- (the individual jobs above can be disabled if the chain is preferred).
-- =============================================================================
SELECT cron.schedule(
    'chain_nightly_batch',
    '0 22 * * *',
    $$
    DO $chain$
    BEGIN
        -- Step 1: Refresh inventory valuation
        REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_inventory_valuation;
        RAISE NOTICE 'Step 1 complete: inventory valuation refreshed';

        -- Step 2: Check reorder points
        PERFORM mfg.fn_check_reorder_points();
        RAISE NOTICE 'Step 2 complete: reorder points checked';

        -- Step 3: Process warranty claims
        PERFORM mfg.fn_process_batch_claims(CURRENT_TIMESTAMP);
        RAISE NOTICE 'Step 3 complete: warranty claims processed';

        -- Step 4: Refresh production backlog
        REFRESH MATERIALIZED VIEW CONCURRENTLY mfg.mv_production_backlog;
        RAISE NOTICE 'Step 4 complete: production backlog refreshed';
    END $chain$;
    $$
);
