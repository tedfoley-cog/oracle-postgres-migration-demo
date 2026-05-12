-- =============================================================================
-- DBMS_SCHEDULER Jobs — Oracle Database 19c
-- Oracle-isms: DBMS_SCHEDULER, DBMS_MVIEW, PL/SQL anonymous blocks,
--              calendar expressions, job chains, event-based scheduling
-- =============================================================================

-- Nightly inventory valuation refresh
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_REFRESH_INV_VALUATION',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_MVIEW.REFRESH(''MFG.MV_INVENTORY_VALUATION'', ''C'');
            DBMS_OUTPUT.PUT_LINE(''Inventory valuation refreshed at '' ||
                TO_CHAR(SYSDATE, ''YYYY-MM-DD HH24:MI:SS''));
        END;',
        start_date      => TRUNC(SYSDATE + 1) + 22/24,  -- 10 PM
        repeat_interval => 'FREQ=DAILY; BYHOUR=22; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Nightly refresh of inventory valuation materialized view'
    );
END;
/

-- Weekly supplier performance refresh
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_REFRESH_SUPPLIER_PERF',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_MVIEW.REFRESH(''MFG.MV_SUPPLIER_PERFORMANCE'', ''C'');
        END;',
        start_date      => NEXT_DAY(TRUNC(SYSDATE), 'SUNDAY') + 6/24,
        repeat_interval => 'FREQ=WEEKLY; BYDAY=SUN; BYHOUR=6; BYMINUTE=0',
        enabled         => TRUE,
        comments        => 'Weekly refresh of supplier performance metrics'
    );
END;
/

-- Monthly warranty cost analysis refresh
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_REFRESH_WARRANTY_COST',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_MVIEW.REFRESH(''MFG.MV_WARRANTY_COST_ANALYSIS'', ''C'');
        END;',
        start_date      => TRUNC(SYSDATE, 'MM') + 1 + 3/24,  -- 1st of month, 3 AM
        repeat_interval => 'FREQ=MONTHLY; BYMONTHDAY=1; BYHOUR=3; BYMINUTE=0',
        enabled         => TRUE,
        comments        => 'Monthly refresh of warranty cost analysis'
    );
END;
/

-- Daily production backlog refresh
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_REFRESH_PROD_BACKLOG',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            DBMS_MVIEW.REFRESH(''MFG.MV_PRODUCTION_BACKLOG'', ''C'');
        END;',
        start_date      => TRUNC(SYSDATE + 1) + 5/24,  -- 5 AM
        repeat_interval => 'FREQ=DAILY; BYHOUR=5; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Daily refresh of production order backlog'
    );
END;
/

-- Nightly warranty claims batch processing
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_PROCESS_WARRANTY_CLAIMS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            MFG.PKG_WARRANTY_CLAIMS.PROCESS_BATCH_CLAIMS(SYSDATE);
        END;',
        start_date      => TRUNC(SYSDATE + 1) + 23/24,  -- 11 PM
        repeat_interval => 'FREQ=DAILY; BYHOUR=23; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Nightly batch processing of pending warranty claims'
    );
END;
/

-- Nightly reorder point check
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MFG.JOB_CHECK_REORDER_POINTS',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'BEGIN
            MFG.PKG_PARTS_INVENTORY.CHECK_REORDER_POINTS;
        END;',
        start_date      => TRUNC(SYSDATE + 1) + 21/24,  -- 9 PM
        repeat_interval => 'FREQ=DAILY; BYHOUR=21; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Nightly check for parts below reorder point'
    );
END;
/

-- Job chain: nightly batch cycle (sequential execution)
BEGIN
    DBMS_SCHEDULER.CREATE_CHAIN(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        comments   => 'Master chain orchestrating nightly batch cycle'
    );

    -- Step 1: Refresh inventory valuation
    DBMS_SCHEDULER.DEFINE_CHAIN_STEP(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        step_name  => 'STEP_INV_REFRESH',
        program_name => 'MFG.JOB_REFRESH_INV_VALUATION'
    );

    -- Step 2: Check reorder points (after inventory refresh)
    DBMS_SCHEDULER.DEFINE_CHAIN_STEP(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        step_name  => 'STEP_REORDER_CHECK',
        program_name => 'MFG.JOB_CHECK_REORDER_POINTS'
    );

    -- Step 3: Process warranty claims
    DBMS_SCHEDULER.DEFINE_CHAIN_STEP(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        step_name  => 'STEP_WARRANTY_BATCH',
        program_name => 'MFG.JOB_PROCESS_WARRANTY_CLAIMS'
    );

    -- Step 4: Refresh production backlog
    DBMS_SCHEDULER.DEFINE_CHAIN_STEP(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        step_name  => 'STEP_PROD_BACKLOG',
        program_name => 'MFG.JOB_REFRESH_PROD_BACKLOG'
    );

    -- Define execution order
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        condition  => 'TRUE',
        action     => 'START STEP_INV_REFRESH'
    );
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        condition  => 'STEP_INV_REFRESH COMPLETED',
        action     => 'START STEP_REORDER_CHECK'
    );
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        condition  => 'STEP_REORDER_CHECK COMPLETED',
        action     => 'START STEP_WARRANTY_BATCH'
    );
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        condition  => 'STEP_WARRANTY_BATCH COMPLETED',
        action     => 'START STEP_PROD_BACKLOG'
    );
    DBMS_SCHEDULER.DEFINE_CHAIN_RULE(
        chain_name => 'MFG.CHAIN_NIGHTLY_BATCH',
        condition  => 'STEP_PROD_BACKLOG COMPLETED',
        action     => 'END'
    );

    DBMS_SCHEDULER.ENABLE('MFG.CHAIN_NIGHTLY_BATCH');
END;
/
