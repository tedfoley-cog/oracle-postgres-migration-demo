-- =============================================================================
-- PKG_PARTS_INVENTORY — Parts Inventory Management
-- Oracle PL/SQL Package (Spec + Body)
-- Handles: inventory transactions, weighted-average costing, reorder alerts
-- Oracle-isms: SYSDATE, NVL, DECODE, autonomous transaction, ROWNUM, %TYPE
-- =============================================================================

CREATE OR REPLACE PACKAGE MFG.PKG_PARTS_INVENTORY AS

    TYPE t_part_rec IS RECORD (
        part_id        MFG.PART_MASTER.PART_ID%TYPE,
        part_number    MFG.PART_MASTER.PART_NUMBER%TYPE,
        description    MFG.PART_MASTER.DESCRIPTION%TYPE,
        on_hand_qty    NUMBER(10,2),
        current_cost   MFG.PART_MASTER.CURRENT_COST%TYPE
    );

    TYPE t_part_cursor IS REF CURSOR RETURN t_part_rec;

    PROCEDURE process_receipt(
        p_part_id       IN NUMBER,
        p_qty           IN NUMBER,
        p_unit_cost     IN NUMBER,
        p_warehouse     IN VARCHAR2 DEFAULT 'WH01',
        p_reference_id  IN NUMBER DEFAULT NULL
    );

    PROCEDURE process_issue(
        p_part_id       IN NUMBER,
        p_qty           IN NUMBER,
        p_warehouse     IN VARCHAR2 DEFAULT 'WH01',
        p_order_id      IN NUMBER DEFAULT NULL
    );

    FUNCTION get_on_hand(
        p_part_id   IN NUMBER,
        p_warehouse IN VARCHAR2 DEFAULT NULL
    ) RETURN NUMBER;

    FUNCTION get_weighted_avg_cost(
        p_part_id IN NUMBER
    ) RETURN NUMBER;

    PROCEDURE check_reorder_points(
        p_plant_code IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE get_inventory_valuation(
        p_cursor    OUT t_part_cursor,
        p_abc_class IN  VARCHAR2 DEFAULT NULL
    );

END PKG_PARTS_INVENTORY;
/

CREATE OR REPLACE PACKAGE BODY MFG.PKG_PARTS_INVENTORY AS

    -- Private: log audit entry using autonomous transaction
    PROCEDURE log_audit(
        p_table     IN VARCHAR2,
        p_operation IN VARCHAR2,
        p_pk_value  IN VARCHAR2,
        p_column    IN VARCHAR2,
        p_old_val   IN VARCHAR2,
        p_new_val   IN VARCHAR2
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO MFG.AUDIT_TRAIL (
            AUDIT_ID, TABLE_NAME, OPERATION, PRIMARY_KEY_VALUE,
            COLUMN_NAME, OLD_VALUE, NEW_VALUE
        ) VALUES (
            MFG.AUDIT_SEQ.NEXTVAL, p_table, p_operation, p_pk_value,
            p_column, p_old_val, p_new_val
        );
        COMMIT;
    END log_audit;

    PROCEDURE process_receipt(
        p_part_id       IN NUMBER,
        p_qty           IN NUMBER,
        p_unit_cost     IN NUMBER,
        p_warehouse     IN VARCHAR2 DEFAULT 'WH01',
        p_reference_id  IN NUMBER DEFAULT NULL
    ) IS
        v_current_qty   NUMBER(10,2);
        v_current_cost  NUMBER(12,4);
        v_new_cost      NUMBER(12,4);
        v_txn_id        NUMBER(15);
    BEGIN
        -- Get current inventory position
        v_current_qty := NVL(get_on_hand(p_part_id, p_warehouse), 0);

        -- Get current weighted average cost
        SELECT NVL(CURRENT_COST, 0)
        INTO   v_current_cost
        FROM   MFG.PART_MASTER
        WHERE  PART_ID = p_part_id;

        -- Calculate new weighted average cost
        IF (v_current_qty + p_qty) > 0 THEN
            v_new_cost := ((v_current_qty * v_current_cost) +
                          (p_qty * p_unit_cost)) /
                          (v_current_qty + p_qty);
        ELSE
            v_new_cost := p_unit_cost;
        END IF;

        -- Record the transaction
        SELECT MFG.PART_SEQ.NEXTVAL INTO v_txn_id FROM DUAL;

        INSERT INTO MFG.INVENTORY_TRANSACTIONS (
            TXN_ID, PART_ID, TXN_TYPE, TXN_QTY, TXN_COST,
            WAREHOUSE_CODE, REFERENCE_TYPE, REFERENCE_ID, TXN_DATE
        ) VALUES (
            v_txn_id, p_part_id, 'RC', p_qty, p_unit_cost,
            p_warehouse,
            DECODE(p_reference_id, NULL, NULL, 'PO'),
            p_reference_id, SYSDATE
        );

        -- Update part master cost
        UPDATE MFG.PART_MASTER
        SET    CURRENT_COST  = v_new_cost,
               MODIFIED_DATE = SYSDATE,
               MODIFIED_BY   = USER
        WHERE  PART_ID = p_part_id;

        log_audit('PART_MASTER', 'UPDATE', TO_CHAR(p_part_id),
                  'CURRENT_COST', TO_CHAR(v_current_cost), TO_CHAR(v_new_cost));

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END process_receipt;

    PROCEDURE process_issue(
        p_part_id       IN NUMBER,
        p_qty           IN NUMBER,
        p_warehouse     IN VARCHAR2 DEFAULT 'WH01',
        p_order_id      IN NUMBER DEFAULT NULL
    ) IS
        v_on_hand   NUMBER(10,2);
        v_cost      NUMBER(12,4);
        v_txn_id    NUMBER(15);
    BEGIN
        v_on_hand := NVL(get_on_hand(p_part_id, p_warehouse), 0);

        IF v_on_hand < p_qty THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Insufficient inventory: on-hand=' || v_on_hand ||
                ' requested=' || p_qty);
        END IF;

        SELECT NVL(CURRENT_COST, 0) INTO v_cost
        FROM   MFG.PART_MASTER
        WHERE  PART_ID = p_part_id;

        SELECT MFG.PART_SEQ.NEXTVAL INTO v_txn_id FROM DUAL;

        INSERT INTO MFG.INVENTORY_TRANSACTIONS (
            TXN_ID, PART_ID, TXN_TYPE, TXN_QTY, TXN_COST,
            WAREHOUSE_CODE, REFERENCE_TYPE, REFERENCE_ID, TXN_DATE
        ) VALUES (
            v_txn_id, p_part_id, 'IS', -p_qty, v_cost,
            p_warehouse,
            DECODE(p_order_id, NULL, NULL, 'WO'),
            p_order_id, SYSDATE
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END process_issue;

    FUNCTION get_on_hand(
        p_part_id   IN NUMBER,
        p_warehouse IN VARCHAR2 DEFAULT NULL
    ) RETURN NUMBER IS
        v_qty NUMBER(10,2);
    BEGIN
        SELECT NVL(SUM(TXN_QTY), 0)
        INTO   v_qty
        FROM   MFG.INVENTORY_TRANSACTIONS
        WHERE  PART_ID = p_part_id
        AND    (p_warehouse IS NULL OR WAREHOUSE_CODE = p_warehouse);

        RETURN v_qty;
    END get_on_hand;

    FUNCTION get_weighted_avg_cost(
        p_part_id IN NUMBER
    ) RETURN NUMBER IS
        v_cost NUMBER(12,4);
    BEGIN
        SELECT NVL(CURRENT_COST, STD_COST)
        INTO   v_cost
        FROM   MFG.PART_MASTER
        WHERE  PART_ID = p_part_id;

        RETURN NVL(v_cost, 0);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
    END get_weighted_avg_cost;

    PROCEDURE check_reorder_points(
        p_plant_code IN VARCHAR2 DEFAULT NULL
    ) IS
        CURSOR c_below_reorder IS
            SELECT p.PART_ID, p.PART_NUMBER, p.DESCRIPTION,
                   p.REORDER_POINT, p.REORDER_QTY,
                   NVL(SUM(it.TXN_QTY), 0) AS on_hand
            FROM   MFG.PART_MASTER p
            LEFT JOIN MFG.INVENTORY_TRANSACTIONS it
                   ON p.PART_ID = it.PART_ID
            WHERE  p.STATUS = 'ACTIVE'
            AND    p.REORDER_POINT > 0
            GROUP BY p.PART_ID, p.PART_NUMBER, p.DESCRIPTION,
                     p.REORDER_POINT, p.REORDER_QTY
            HAVING NVL(SUM(it.TXN_QTY), 0) < p.REORDER_POINT;
    BEGIN
        FOR r IN c_below_reorder LOOP
            DBMS_OUTPUT.PUT_LINE(
                'REORDER ALERT: ' || r.PART_NUMBER ||
                ' (' || r.DESCRIPTION || ')' ||
                ' On-Hand: ' || r.on_hand ||
                ' Reorder Point: ' || r.REORDER_POINT ||
                ' Suggested Qty: ' || r.REORDER_QTY
            );
        END LOOP;
    END check_reorder_points;

    PROCEDURE get_inventory_valuation(
        p_cursor    OUT t_part_cursor,
        p_abc_class IN  VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        OPEN p_cursor FOR
            SELECT p.PART_ID, p.PART_NUMBER, p.DESCRIPTION,
                   NVL(SUM(it.TXN_QTY), 0) AS on_hand_qty,
                   p.CURRENT_COST
            FROM   MFG.PART_MASTER p
            LEFT JOIN MFG.INVENTORY_TRANSACTIONS it
                   ON p.PART_ID = it.PART_ID
            WHERE  p.STATUS = 'ACTIVE'
            AND    (p_abc_class IS NULL OR p.ABC_CLASS = p_abc_class)
            GROUP BY p.PART_ID, p.PART_NUMBER, p.DESCRIPTION, p.CURRENT_COST
            ORDER BY p.PART_NUMBER;
    END get_inventory_valuation;

END PKG_PARTS_INVENTORY;
/
