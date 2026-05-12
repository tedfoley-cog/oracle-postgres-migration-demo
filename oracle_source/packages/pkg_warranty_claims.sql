-- =============================================================================
-- PKG_WARRANTY_CLAIMS — Warranty Claims Processing and Settlement
-- Oracle PL/SQL Package (Spec + Body)
-- Oracle-isms: SYSDATE, MONTHS_BETWEEN, NVL, DECODE, ROWNUM,
--              DBMS_OUTPUT, cursor FOR UPDATE, exception handling
-- =============================================================================

CREATE OR REPLACE PACKAGE MFG.PKG_WARRANTY_CLAIMS AS

    -- Warranty type constants
    C_BASIC_WARRANTY     CONSTANT VARCHAR2(2) := 'BW';  -- 36 mo / 36,000 mi
    C_POWERTRAIN         CONSTANT VARCHAR2(2) := 'PT';  -- 60 mo / 60,000 mi
    C_EMISSIONS          CONSTANT VARCHAR2(2) := 'EM';  -- 96 mo / 80,000 mi
    C_CORROSION          CONSTANT VARCHAR2(2) := 'CR';  -- 120 mo / unlimited

    TYPE t_claim_summary IS RECORD (
        total_claims    NUMBER,
        total_settled   NUMBER(14,2),
        avg_settlement  NUMBER(12,2),
        rejection_rate  NUMBER(5,2)
    );

    FUNCTION validate_claim(
        p_claim_id IN NUMBER
    ) RETURN VARCHAR2;

    PROCEDURE calculate_settlement(
        p_claim_id IN NUMBER
    );

    PROCEDURE process_batch_claims(
        p_batch_date IN DATE DEFAULT SYSDATE
    );

    FUNCTION get_claim_summary(
        p_dealer_code  IN VARCHAR2 DEFAULT NULL,
        p_start_date   IN DATE DEFAULT NULL,
        p_end_date     IN DATE DEFAULT NULL
    ) RETURN t_claim_summary;

    FUNCTION get_top_defects(
        p_top_n     IN NUMBER DEFAULT 10,
        p_start_date IN DATE DEFAULT ADD_MONTHS(SYSDATE, -12)
    ) RETURN SYS_REFCURSOR;

END PKG_WARRANTY_CLAIMS;
/

CREATE OR REPLACE PACKAGE BODY MFG.PKG_WARRANTY_CLAIMS AS

    -- Private: get warranty period limits
    PROCEDURE get_warranty_limits(
        p_warranty_type IN  VARCHAR2,
        p_max_months    OUT NUMBER,
        p_max_mileage   OUT NUMBER
    ) IS
    BEGIN
        p_max_months  := DECODE(p_warranty_type,
                                'BW', 36, 'PT', 60, 'EM', 96, 'CR', 120, 0);
        p_max_mileage := DECODE(p_warranty_type,
                                'BW', 36000, 'PT', 60000, 'EM', 80000,
                                'CR', 999999, 0);
    END get_warranty_limits;

    FUNCTION validate_claim(
        p_claim_id IN NUMBER
    ) RETURN VARCHAR2 IS
        v_claim       MFG.WARRANTY_CLAIMS%ROWTYPE;
        v_max_months  NUMBER;
        v_max_mileage NUMBER;
        v_age_months  NUMBER;
    BEGIN
        SELECT * INTO v_claim
        FROM   MFG.WARRANTY_CLAIMS
        WHERE  CLAIM_ID = p_claim_id;

        get_warranty_limits(v_claim.WARRANTY_TYPE, v_max_months, v_max_mileage);

        -- Check warranty period
        v_age_months := MONTHS_BETWEEN(
            NVL(v_claim.REPAIR_DATE, SYSDATE),
            v_claim.SALE_DATE
        );

        IF v_age_months > v_max_months THEN
            RETURN 'REJECTED: Warranty period expired (' ||
                   ROUND(v_age_months, 1) || ' months, max ' ||
                   v_max_months || ')';
        END IF;

        -- Check mileage (except corrosion = unlimited)
        IF v_claim.WARRANTY_TYPE != C_CORROSION
           AND NVL(v_claim.MILEAGE, 0) > v_max_mileage THEN
            RETURN 'REJECTED: Mileage exceeded (' ||
                   v_claim.MILEAGE || ' mi, max ' || v_max_mileage || ')';
        END IF;

        RETURN 'VALID';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'ERROR: Claim not found';
    END validate_claim;

    PROCEDURE calculate_settlement(
        p_claim_id IN NUMBER
    ) IS
        v_claim         MFG.WARRANTY_CLAIMS%ROWTYPE;
        v_validation    VARCHAR2(200);
        v_settlement    NUMBER(12,2);
        v_coverage_pct  NUMBER(5,2) := 100;
        v_age_months    NUMBER;
        v_max_months    NUMBER;
        v_max_mileage   NUMBER;
    BEGIN
        SELECT * INTO v_claim
        FROM   MFG.WARRANTY_CLAIMS
        WHERE  CLAIM_ID = p_claim_id
        FOR UPDATE;

        v_validation := validate_claim(p_claim_id);

        IF v_validation != 'VALID' THEN
            UPDATE MFG.WARRANTY_CLAIMS
            SET    DISPOSITION  = 'REJECTED',
                   PROCESS_DATE = SYSDATE
            WHERE  CLAIM_ID = p_claim_id;
            COMMIT;
            RETURN;
        END IF;

        -- Calculate base settlement
        v_settlement := NVL(v_claim.LABOR_HOURS, 0) *
                        NVL(v_claim.LABOR_RATE, 0) +
                        NVL(v_claim.PARTS_COST, 0) +
                        NVL(v_claim.SUBLET_COST, 0);

        -- Corrosion warranty: declining coverage after 60 months (min 50%)
        IF v_claim.WARRANTY_TYPE = C_CORROSION THEN
            v_age_months := MONTHS_BETWEEN(
                NVL(v_claim.REPAIR_DATE, SYSDATE), v_claim.SALE_DATE
            );
            IF v_age_months > 60 THEN
                get_warranty_limits(C_CORROSION, v_max_months, v_max_mileage);
                v_coverage_pct := GREATEST(50,
                    100 - ((v_age_months - 60) / (v_max_months - 60) * 50));
            END IF;
            v_settlement := v_settlement * (v_coverage_pct / 100);
        END IF;

        -- Update claim with settlement
        UPDATE MFG.WARRANTY_CLAIMS
        SET    SETTLEMENT_AMT = v_settlement,
               DISPOSITION    = 'APPROVED',
               PROCESS_DATE   = SYSDATE
        WHERE  CLAIM_ID = p_claim_id;

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END calculate_settlement;

    PROCEDURE process_batch_claims(
        p_batch_date IN DATE DEFAULT SYSDATE
    ) IS
        v_processed NUMBER := 0;
        v_errors    NUMBER := 0;
    BEGIN
        FOR r IN (
            SELECT CLAIM_ID
            FROM   MFG.WARRANTY_CLAIMS
            WHERE  DISPOSITION = 'PENDING'
            AND    TRUNC(CREATED_DATE) <= TRUNC(p_batch_date)
            ORDER BY CREATED_DATE
        ) LOOP
            BEGIN
                calculate_settlement(r.CLAIM_ID);
                v_processed := v_processed + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    v_errors := v_errors + 1;
                    DBMS_OUTPUT.PUT_LINE(
                        'Error processing claim ' || r.CLAIM_ID ||
                        ': ' || SQLERRM
                    );
            END;
        END LOOP;

        DBMS_OUTPUT.PUT_LINE(
            'Batch complete: ' || v_processed || ' processed, ' ||
            v_errors || ' errors'
        );
    END process_batch_claims;

    FUNCTION get_claim_summary(
        p_dealer_code  IN VARCHAR2 DEFAULT NULL,
        p_start_date   IN DATE DEFAULT NULL,
        p_end_date     IN DATE DEFAULT NULL
    ) RETURN t_claim_summary IS
        v_summary t_claim_summary;
    BEGIN
        SELECT COUNT(*),
               NVL(SUM(SETTLEMENT_AMT), 0),
               NVL(AVG(SETTLEMENT_AMT), 0),
               ROUND(
                   SUM(DECODE(DISPOSITION, 'REJECTED', 1, 0)) /
                   GREATEST(COUNT(*), 1) * 100, 2
               )
        INTO   v_summary.total_claims,
               v_summary.total_settled,
               v_summary.avg_settlement,
               v_summary.rejection_rate
        FROM   MFG.WARRANTY_CLAIMS
        WHERE  (p_dealer_code IS NULL OR DEALER_CODE = p_dealer_code)
        AND    (p_start_date IS NULL OR CREATED_DATE >= p_start_date)
        AND    (p_end_date IS NULL OR CREATED_DATE <= p_end_date);

        RETURN v_summary;
    END get_claim_summary;

    FUNCTION get_top_defects(
        p_top_n      IN NUMBER DEFAULT 10,
        p_start_date IN DATE DEFAULT ADD_MONTHS(SYSDATE, -12)
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT * FROM (
                SELECT DEFECT_CODE,
                       COUNT(*) AS claim_count,
                       SUM(NVL(SETTLEMENT_AMT, 0)) AS total_cost,
                       ROUND(AVG(NVL(SETTLEMENT_AMT, 0)), 2) AS avg_cost
                FROM   MFG.WARRANTY_CLAIMS
                WHERE  CREATED_DATE >= p_start_date
                AND    DEFECT_CODE IS NOT NULL
                GROUP BY DEFECT_CODE
                ORDER BY claim_count DESC
            ) WHERE ROWNUM <= p_top_n;

        RETURN v_cursor;
    END get_top_defects;

END PKG_WARRANTY_CLAIMS;
/
