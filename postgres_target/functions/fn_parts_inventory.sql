-- =============================================================================
-- PL/pgSQL Functions — Parts Inventory Management
-- Migrated from Oracle PKG_PARTS_INVENTORY (spec + body)
-- Migration notes:
--   PACKAGE → set of standalone functions in mfg schema
--   PRAGMA AUTONOMOUS_TRANSACTION → dblink for independent transaction
--   NVL(a,b)                     → COALESCE(a,b)
--   DECODE(a,b,c,d)              → CASE WHEN a = b THEN c ELSE d END
--   SYSDATE                      → CURRENT_TIMESTAMP
--   USER                         → CURRENT_USER
--   SELECT ... FROM DUAL         → SELECT ... (no FROM needed)
--   RAISE_APPLICATION_ERROR      → RAISE EXCEPTION
--   DBMS_OUTPUT.PUT_LINE         → RAISE NOTICE
--   %TYPE                        → explicit column type references
--   REF CURSOR                   → RETURNS TABLE / refcursor
-- =============================================================================

-- Private helper: log audit entry using dblink (autonomous transaction)
-- Replaces PRAGMA AUTONOMOUS_TRANSACTION
CREATE OR REPLACE FUNCTION mfg.fn_log_audit(
    p_table     VARCHAR,
    p_operation VARCHAR,
    p_pk_value  VARCHAR,
    p_column    VARCHAR,
    p_old_val   VARCHAR,
    p_new_val   VARCHAR
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM dblink_exec(
        'dbname=' || current_database(),
        'INSERT INTO mfg.audit_trail (
            audit_id, table_name, operation, primary_key_value,
            column_name, old_value, new_value
        ) VALUES (
            nextval(''mfg.audit_seq''), ' ||
            quote_literal(p_table) || ', ' ||
            quote_literal(p_operation) || ', ' ||
            quote_literal(p_pk_value) || ', ' ||
            quote_literal(p_column) || ', ' ||
            COALESCE(quote_literal(p_old_val), 'NULL') || ', ' ||
            COALESCE(quote_literal(p_new_val), 'NULL') || ')'
    );
END;
$$;

-- Process inventory receipt with weighted-average costing
CREATE OR REPLACE FUNCTION mfg.fn_process_receipt(
    p_part_id       BIGINT,
    p_qty           NUMERIC,
    p_unit_cost     NUMERIC,
    p_warehouse     VARCHAR DEFAULT 'WH01',
    p_reference_id  BIGINT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_qty   NUMERIC(10,2);
    v_current_cost  NUMERIC(12,4);
    v_new_cost      NUMERIC(12,4);
    v_txn_id        BIGINT;
BEGIN
    v_current_qty := COALESCE(mfg.fn_get_on_hand(p_part_id, p_warehouse), 0);

    SELECT COALESCE(current_cost, 0)
    INTO   v_current_cost
    FROM   mfg.part_master
    WHERE  part_id = p_part_id;

    IF (v_current_qty + p_qty) > 0 THEN
        v_new_cost := ((v_current_qty * v_current_cost) +
                      (p_qty * p_unit_cost)) /
                      (v_current_qty + p_qty);
    ELSE
        v_new_cost := p_unit_cost;
    END IF;

    v_txn_id := nextval('mfg.part_seq');

    INSERT INTO mfg.inventory_transactions (
        txn_id, part_id, txn_type, txn_qty, txn_cost,
        warehouse_code, reference_type, reference_id, txn_date
    ) VALUES (
        v_txn_id, p_part_id, 'RC', p_qty, p_unit_cost,
        p_warehouse,
        CASE WHEN p_reference_id IS NULL THEN NULL ELSE 'PO' END,
        p_reference_id, CURRENT_TIMESTAMP
    );

    UPDATE mfg.part_master
    SET    current_cost  = v_new_cost,
           modified_date = CURRENT_TIMESTAMP,
           modified_by   = CURRENT_USER
    WHERE  part_id = p_part_id;

    PERFORM mfg.fn_log_audit('part_master', 'UPDATE', p_part_id::TEXT,
              'current_cost', v_current_cost::TEXT, v_new_cost::TEXT);
END;
$$;

-- Process inventory issue (withdrawal)
CREATE OR REPLACE FUNCTION mfg.fn_process_issue(
    p_part_id       BIGINT,
    p_qty           NUMERIC,
    p_warehouse     VARCHAR DEFAULT 'WH01',
    p_order_id      BIGINT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_on_hand   NUMERIC(10,2);
    v_cost      NUMERIC(12,4);
    v_txn_id    BIGINT;
BEGIN
    v_on_hand := COALESCE(mfg.fn_get_on_hand(p_part_id, p_warehouse), 0);

    IF v_on_hand < p_qty THEN
        RAISE EXCEPTION 'Insufficient inventory: on-hand=% requested=%',
            v_on_hand, p_qty;
    END IF;

    SELECT COALESCE(current_cost, 0) INTO v_cost
    FROM   mfg.part_master
    WHERE  part_id = p_part_id;

    v_txn_id := nextval('mfg.part_seq');

    INSERT INTO mfg.inventory_transactions (
        txn_id, part_id, txn_type, txn_qty, txn_cost,
        warehouse_code, reference_type, reference_id, txn_date
    ) VALUES (
        v_txn_id, p_part_id, 'IS', -p_qty, v_cost,
        p_warehouse,
        CASE WHEN p_order_id IS NULL THEN NULL ELSE 'WO' END,
        p_order_id, CURRENT_TIMESTAMP
    );
END;
$$;

-- Get current on-hand quantity
CREATE OR REPLACE FUNCTION mfg.fn_get_on_hand(
    p_part_id   BIGINT,
    p_warehouse VARCHAR DEFAULT NULL
) RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_qty NUMERIC(10,2);
BEGIN
    SELECT COALESCE(SUM(txn_qty), 0)
    INTO   v_qty
    FROM   mfg.inventory_transactions
    WHERE  part_id = p_part_id
    AND    (p_warehouse IS NULL OR warehouse_code = p_warehouse);

    RETURN v_qty;
END;
$$;

-- Get weighted average cost for a part
CREATE OR REPLACE FUNCTION mfg.fn_get_weighted_avg_cost(
    p_part_id BIGINT
) RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_cost NUMERIC(12,4);
BEGIN
    SELECT COALESCE(current_cost, std_cost)
    INTO   v_cost
    FROM   mfg.part_master
    WHERE  part_id = p_part_id;

    RETURN COALESCE(v_cost, 0);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END;
$$;

-- Check reorder points and raise notices
-- Oracle DBMS_OUTPUT.PUT_LINE → RAISE NOTICE
CREATE OR REPLACE FUNCTION mfg.fn_check_reorder_points(
    p_plant_code VARCHAR DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT p.part_id, p.part_number, p.description,
               p.reorder_point, p.reorder_qty,
               COALESCE(SUM(it.txn_qty), 0) AS on_hand
        FROM   mfg.part_master p
        LEFT JOIN mfg.inventory_transactions it
               ON p.part_id = it.part_id
        WHERE  p.status = 'ACTIVE'
        AND    p.reorder_point > 0
        GROUP BY p.part_id, p.part_number, p.description,
                 p.reorder_point, p.reorder_qty
        HAVING COALESCE(SUM(it.txn_qty), 0) < p.reorder_point
    LOOP
        RAISE NOTICE 'REORDER ALERT: % (%) On-Hand: % Reorder Point: % Suggested Qty: %',
            r.part_number, r.description, r.on_hand,
            r.reorder_point, r.reorder_qty;
    END LOOP;
END;
$$;

-- Get inventory valuation as a result set
-- Oracle REF CURSOR OUT parameter → RETURNS TABLE
CREATE OR REPLACE FUNCTION mfg.fn_get_inventory_valuation(
    p_abc_class VARCHAR DEFAULT NULL
) RETURNS TABLE (
    part_id      BIGINT,
    part_number  VARCHAR(20),
    description  VARCHAR(100),
    on_hand_qty  NUMERIC(10,2),
    current_cost NUMERIC(12,4)
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT p.part_id, p.part_number, p.description,
               COALESCE(SUM(it.txn_qty), 0)::NUMERIC(10,2) AS on_hand_qty,
               p.current_cost
        FROM   mfg.part_master p
        LEFT JOIN mfg.inventory_transactions it
               ON p.part_id = it.part_id
        WHERE  p.status = 'ACTIVE'
        AND    (p_abc_class IS NULL OR p.abc_class = p_abc_class)
        GROUP BY p.part_id, p.part_number, p.description, p.current_cost
        ORDER BY p.part_number;
END;
$$;
