-- =============================================================================
-- PostgreSQL Triggers — Migrated from Oracle Database 19c
-- Migration notes:
--   :NEW / :OLD            → NEW / OLD (no colon prefix)
--   RAISE_APPLICATION_ERROR → RAISE EXCEPTION
--   SYSDATE                → CURRENT_TIMESTAMP
--   USER                   → CURRENT_USER
--   NVL(a,b)               → COALESCE(a,b)
--   Oracle trigger body    → separate trigger FUNCTION + trigger binding
--   WHEN (condition)       → WHEN (condition) on CREATE TRIGGER
--   CURRVAL                → currval('sequence_name')
-- =============================================================================

-- 1. Auto-populate PART_ID from sequence on insert
CREATE OR REPLACE FUNCTION mfg.trg_part_master_bi_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.part_id IS NULL THEN
        NEW.part_id := nextval('mfg.part_seq');
    END IF;
    NEW.created_date := COALESCE(NEW.created_date, CURRENT_TIMESTAMP);
    NEW.modified_date := CURRENT_TIMESTAMP;
    NEW.modified_by := CURRENT_USER;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_part_master_bi
    BEFORE INSERT ON mfg.part_master
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_part_master_bi_fn();

-- 2. Track cost changes on part master (audit trigger)
CREATE OR REPLACE FUNCTION mfg.trg_part_cost_audit_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO mfg.audit_trail (
        audit_id, table_name, operation, primary_key_value,
        column_name, old_value, new_value, changed_by, changed_date
    ) VALUES (
        nextval('mfg.audit_seq'), 'part_master', 'UPDATE',
        NEW.part_id::TEXT, 'current_cost',
        OLD.current_cost::TEXT, NEW.current_cost::TEXT,
        CURRENT_USER, CURRENT_TIMESTAMP
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_part_cost_audit
    AFTER UPDATE OF current_cost ON mfg.part_master
    FOR EACH ROW
    WHEN (COALESCE(OLD.current_cost, 0) != COALESCE(NEW.current_cost, 0))
    EXECUTE FUNCTION mfg.trg_part_cost_audit_fn();

-- 3. Auto-populate ORDER_ID, generate order number, validate dates
CREATE OR REPLACE FUNCTION mfg.trg_prod_order_bi_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.order_id IS NULL THEN
        NEW.order_id := nextval('mfg.order_seq');
    END IF;

    IF NEW.order_number IS NULL THEN
        NEW.order_number := 'WO-' ||
            TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDD') || '-' ||
            LPAD(currval('mfg.order_seq')::TEXT, 6, '0');
    END IF;

    IF NEW.due_date < NEW.order_date THEN
        RAISE EXCEPTION 'Due date cannot be before order date';
    END IF;

    NEW.created_date := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prod_order_bi
    BEFORE INSERT ON mfg.production_orders
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_prod_order_bi_fn();

-- 4. Prevent deletion of parts with active BOM references
CREATE OR REPLACE FUNCTION mfg.trg_part_delete_check_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ref_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_ref_count
    FROM   mfg.bill_of_materials
    WHERE  parent_part_id = OLD.part_id
    OR     component_part_id = OLD.part_id;

    IF v_ref_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete part %: referenced in % BOM records',
            OLD.part_number, v_ref_count;
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_part_delete_check
    BEFORE DELETE ON mfg.part_master
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_part_delete_check_fn();

-- 5. Auto-populate claim ID and default dates
CREATE OR REPLACE FUNCTION mfg.trg_warranty_claim_bi_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.claim_id IS NULL THEN
        NEW.claim_id := nextval('mfg.claim_seq');
    END IF;

    IF NEW.claim_number IS NULL THEN
        NEW.claim_number := 'CLM-' ||
            TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDD') || '-' ||
            LPAD(NEW.claim_id::TEXT, 6, '0');
    END IF;

    NEW.created_date := CURRENT_TIMESTAMP;
    NEW.disposition := COALESCE(NEW.disposition, 'PENDING');
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_warranty_claim_bi
    BEFORE INSERT ON mfg.warranty_claims
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_warranty_claim_bi_fn();

-- 6. Update production order status based on completion
CREATE OR REPLACE FUNCTION mfg.trg_prod_order_status_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.completed_qty >= NEW.order_qty THEN
        NEW.status := 'COMPLETED';
        NEW.completion_date := COALESCE(NEW.completion_date, CURRENT_TIMESTAMP);
    ELSIF NEW.completed_qty > 0 THEN
        NEW.status := 'IN_PROGRESS';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prod_order_status
    BEFORE UPDATE OF completed_qty ON mfg.production_orders
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_prod_order_status_fn();

-- 7. Auto-populate inspection ID
CREATE OR REPLACE FUNCTION mfg.trg_inspection_bi_fn()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.inspection_id IS NULL THEN
        NEW.inspection_id := nextval('mfg.inspection_seq');
    END IF;
    NEW.created_date := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inspection_bi
    BEFORE INSERT ON mfg.quality_inspections
    FOR EACH ROW
    EXECUTE FUNCTION mfg.trg_inspection_bi_fn();
