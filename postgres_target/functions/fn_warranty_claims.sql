-- =============================================================================
-- PL/pgSQL Functions — Warranty Claims Processing and Settlement
-- Migrated from Oracle PKG_WARRANTY_CLAIMS (spec + body)
-- Migration notes:
--   DECODE(a,b1,c1,b2,c2,...,d) → CASE WHEN a=b1 THEN c1 ... ELSE d END
--   NVL(a,b)                    → COALESCE(a,b)
--   SYSDATE                     → CURRENT_TIMESTAMP
--   MONTHS_BETWEEN(a,b)         → EXTRACT(EPOCH FROM AGE(a,b)) / 2592000
--   ADD_MONTHS(d,n)             → d + INTERVAL 'n months'
--   ROWNUM <= n                 → LIMIT n (or FETCH FIRST n ROWS ONLY)
--   RAISE_APPLICATION_ERROR     → RAISE EXCEPTION
--   DBMS_OUTPUT.PUT_LINE        → RAISE NOTICE
--   SYS_REFCURSOR               → refcursor / RETURNS TABLE
--   FOR UPDATE                  → FOR UPDATE (same in PostgreSQL)
-- =============================================================================

-- Private helper: get warranty period limits
-- Oracle DECODE → CASE expression
CREATE OR REPLACE FUNCTION mfg.fn_get_warranty_limits(
    p_warranty_type VARCHAR
) RETURNS TABLE (
    max_months  INTEGER,
    max_mileage INTEGER
)
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    max_months := CASE p_warranty_type
        WHEN 'BW' THEN 36
        WHEN 'PT' THEN 60
        WHEN 'EM' THEN 96
        WHEN 'CR' THEN 120
        ELSE 0
    END;
    max_mileage := CASE p_warranty_type
        WHEN 'BW' THEN 36000
        WHEN 'PT' THEN 60000
        WHEN 'EM' THEN 80000
        WHEN 'CR' THEN 999999
        ELSE 0
    END;
    RETURN NEXT;
END;
$$;

-- Validate a warranty claim
-- Oracle MONTHS_BETWEEN → EXTRACT(EPOCH FROM AGE(...))/2592000
CREATE OR REPLACE FUNCTION mfg.fn_validate_claim(
    p_claim_id BIGINT
) RETURNS VARCHAR
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_claim       mfg.warranty_claims%ROWTYPE;
    v_max_months  INTEGER;
    v_max_mileage INTEGER;
    v_age_months  NUMERIC;
BEGIN
    SELECT * INTO v_claim
    FROM   mfg.warranty_claims
    WHERE  claim_id = p_claim_id;

    IF NOT FOUND THEN
        RETURN 'ERROR: Claim not found';
    END IF;

    SELECT wl.max_months, wl.max_mileage
    INTO   v_max_months, v_max_mileage
    FROM   mfg.fn_get_warranty_limits(v_claim.warranty_type) wl;

    v_age_months := EXTRACT(EPOCH FROM AGE(
        COALESCE(v_claim.repair_date, CURRENT_TIMESTAMP),
        v_claim.sale_date
    )) / 2592000.0;

    IF v_age_months > v_max_months THEN
        RETURN 'REJECTED: Warranty period expired (' ||
               ROUND(v_age_months, 1) || ' months, max ' ||
               v_max_months || ')';
    END IF;

    IF v_claim.warranty_type != 'CR'
       AND COALESCE(v_claim.mileage, 0) > v_max_mileage THEN
        RETURN 'REJECTED: Mileage exceeded (' ||
               v_claim.mileage || ' mi, max ' || v_max_mileage || ')';
    END IF;

    RETURN 'VALID';
END;
$$;

-- Calculate and apply settlement amount for a claim
CREATE OR REPLACE FUNCTION mfg.fn_calculate_settlement(
    p_claim_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim         mfg.warranty_claims%ROWTYPE;
    v_validation    VARCHAR(200);
    v_settlement    NUMERIC(12,2);
    v_coverage_pct  NUMERIC(5,2) := 100;
    v_age_months    NUMERIC;
    v_max_months    INTEGER;
    v_max_mileage   INTEGER;
BEGIN
    SELECT * INTO v_claim
    FROM   mfg.warranty_claims
    WHERE  claim_id = p_claim_id
    FOR UPDATE;

    v_validation := mfg.fn_validate_claim(p_claim_id);

    IF v_validation != 'VALID' THEN
        UPDATE mfg.warranty_claims
        SET    disposition  = 'REJECTED',
               process_date = CURRENT_TIMESTAMP
        WHERE  claim_id = p_claim_id;
        RETURN;
    END IF;

    v_settlement := COALESCE(v_claim.labor_hours, 0) *
                    COALESCE(v_claim.labor_rate, 0) +
                    COALESCE(v_claim.parts_cost, 0) +
                    COALESCE(v_claim.sublet_cost, 0);

    IF v_claim.warranty_type = 'CR' THEN
        v_age_months := EXTRACT(EPOCH FROM AGE(
            COALESCE(v_claim.repair_date, CURRENT_TIMESTAMP), v_claim.sale_date
        )) / 2592000.0;

        IF v_age_months > 60 THEN
            SELECT wl.max_months, wl.max_mileage
            INTO   v_max_months, v_max_mileage
            FROM   mfg.fn_get_warranty_limits('CR') wl;

            v_coverage_pct := GREATEST(50,
                100 - ((v_age_months - 60) / (v_max_months - 60) * 50));
        END IF;
        v_settlement := v_settlement * (v_coverage_pct / 100);
    END IF;

    UPDATE mfg.warranty_claims
    SET    settlement_amt = v_settlement,
           disposition    = 'APPROVED',
           process_date   = CURRENT_TIMESTAMP
    WHERE  claim_id = p_claim_id;
END;
$$;

-- Batch process pending warranty claims
-- Oracle DBMS_OUTPUT.PUT_LINE → RAISE NOTICE
CREATE OR REPLACE FUNCTION mfg.fn_process_batch_claims(
    p_batch_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    r           RECORD;
    v_processed INTEGER := 0;
    v_errors    INTEGER := 0;
BEGIN
    FOR r IN
        SELECT claim_id
        FROM   mfg.warranty_claims
        WHERE  disposition = 'PENDING'
        AND    created_date::DATE <= p_batch_date::DATE
        ORDER BY created_date
    LOOP
        BEGIN
            PERFORM mfg.fn_calculate_settlement(r.claim_id);
            v_processed := v_processed + 1;
        EXCEPTION
            WHEN OTHERS THEN
                v_errors := v_errors + 1;
                RAISE NOTICE 'Error processing claim %: %', r.claim_id, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE 'Batch complete: % processed, % errors', v_processed, v_errors;
END;
$$;

-- Get claim summary statistics
-- Oracle DECODE → CASE, NVL → COALESCE
CREATE OR REPLACE FUNCTION mfg.fn_get_claim_summary(
    p_dealer_code  VARCHAR DEFAULT NULL,
    p_start_date   TIMESTAMP DEFAULT NULL,
    p_end_date     TIMESTAMP DEFAULT NULL
) RETURNS TABLE (
    total_claims    BIGINT,
    total_settled   NUMERIC(14,2),
    avg_settlement  NUMERIC(12,2),
    rejection_rate  NUMERIC(5,2)
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT COUNT(*)::BIGINT,
           COALESCE(SUM(wc.settlement_amt), 0)::NUMERIC(14,2),
           COALESCE(AVG(wc.settlement_amt), 0)::NUMERIC(12,2),
           ROUND(
               SUM(CASE WHEN wc.disposition = 'REJECTED' THEN 1 ELSE 0 END)::NUMERIC /
               GREATEST(COUNT(*), 1) * 100, 2
           )::NUMERIC(5,2)
    FROM   mfg.warranty_claims wc
    WHERE  (p_dealer_code IS NULL OR wc.dealer_code = p_dealer_code)
    AND    (p_start_date IS NULL OR wc.created_date >= p_start_date)
    AND    (p_end_date IS NULL OR wc.created_date <= p_end_date);
END;
$$;

-- Get top defect codes by claim count
-- Oracle ROWNUM <= n → LIMIT n
CREATE OR REPLACE FUNCTION mfg.fn_get_top_defects(
    p_top_n      INTEGER DEFAULT 10,
    p_start_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP - INTERVAL '12 months'
) RETURNS TABLE (
    defect_code  VARCHAR(6),
    claim_count  BIGINT,
    total_cost   NUMERIC,
    avg_cost     NUMERIC
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT wc.defect_code,
           COUNT(*)::BIGINT AS claim_count,
           SUM(COALESCE(wc.settlement_amt, 0)) AS total_cost,
           ROUND(AVG(COALESCE(wc.settlement_amt, 0)), 2) AS avg_cost
    FROM   mfg.warranty_claims wc
    WHERE  wc.created_date >= p_start_date
    AND    wc.defect_code IS NOT NULL
    GROUP BY wc.defect_code
    ORDER BY claim_count DESC
    LIMIT p_top_n;
END;
$$;
