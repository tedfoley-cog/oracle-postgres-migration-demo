-- =============================================================================
-- PL/pgSQL Functions — BOM Explosion and Costed Rollup
-- Migrated from Oracle PKG_BOM_PROCESSOR (spec + body)
-- Migration notes:
--   CONNECT BY PRIOR           → WITH RECURSIVE
--   SYS_CONNECT_BY_PATH        → String concatenation in recursive CTE
--   LEVEL                      → depth counter in recursive CTE
--   CONNECT_BY_ISCYCLE / NOCYCLE → cycle detection via path tracking
--   PIPELINED TABLE FUNCTION   → RETURNS TABLE (set-returning function)
--   BULK COLLECT INTO          → RETURNS TABLE (materialized via query)
--   ORDER SIBLINGS BY          → ORDER BY within each recursion level
--   NVL(a,b)                   → COALESCE(a,b)
--   SYSDATE                    → CURRENT_TIMESTAMP
-- =============================================================================

-- Explode BOM using recursive CTE (replaces CONNECT BY PRIOR + PIPELINED)
CREATE OR REPLACE FUNCTION mfg.fn_explode_bom(
    p_parent_part_id BIGINT,
    p_qty            NUMERIC DEFAULT 1,
    p_effective_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) RETURNS TABLE (
    bom_level     INTEGER,
    part_id       BIGINT,
    part_number   VARCHAR(20),
    description   VARCHAR(100),
    qty_required  NUMERIC(12,4),
    extended_cost NUMERIC(14,4),
    bom_path      TEXT
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE bom_tree AS (
        -- Anchor: direct children of the parent
        SELECT
            1 AS bom_level,
            p.part_id,
            p.part_number,
            p.description,
            (b.qty_per_assembly * (1 + COALESCE(b.scrap_factor, 0)) * p_qty)::NUMERIC(12,4)
                AS qty_required,
            p.current_cost,
            ' / ' || p.part_number AS bom_path
        FROM   mfg.bill_of_materials b
        JOIN   mfg.part_master p ON p.part_id = b.component_part_id
        WHERE  b.parent_part_id = p_parent_part_id
        AND    b.effectivity_start <= p_effective_date
        AND    COALESCE(b.effectivity_end, p_effective_date + INTERVAL '1 day') > p_effective_date

        UNION ALL

        -- Recursive: children of children
        SELECT
            bt.bom_level + 1,
            p.part_id,
            p.part_number,
            p.description,
            (b.qty_per_assembly * (1 + COALESCE(b.scrap_factor, 0)) * p_qty)::NUMERIC(12,4),
            p.current_cost,
            bt.bom_path || ' / ' || p.part_number
        FROM   bom_tree bt
        JOIN   mfg.bill_of_materials b ON b.parent_part_id = bt.part_id
        JOIN   mfg.part_master p ON p.part_id = b.component_part_id
        WHERE  bt.bom_level < 15
        AND    b.effectivity_start <= p_effective_date
        AND    COALESCE(b.effectivity_end, p_effective_date + INTERVAL '1 day') > p_effective_date
    )
    SELECT
        bt.bom_level,
        bt.part_id,
        bt.part_number,
        bt.description,
        bt.qty_required,
        (bt.qty_required * COALESCE(bt.current_cost, 0))::NUMERIC(14,4) AS extended_cost,
        bt.bom_path
    FROM   bom_tree bt
    ORDER BY bt.bom_path;
END;
$$;

-- Get costed rollup — sum of all leaf-level component costs
CREATE OR REPLACE FUNCTION mfg.fn_get_costed_rollup(
    p_parent_part_id BIGINT,
    p_effective_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_total_cost NUMERIC(14,4) := 0;
BEGIN
    SELECT COALESCE(SUM(b.extended_cost), 0)
    INTO   v_total_cost
    FROM   mfg.fn_explode_bom(p_parent_part_id, 1, p_effective_date) b
    WHERE  NOT EXISTS (
        SELECT 1 FROM mfg.bill_of_materials bom
        WHERE  bom.parent_part_id = b.part_id
        AND    bom.effectivity_start <= p_effective_date
        AND    COALESCE(bom.effectivity_end, p_effective_date + INTERVAL '1 day') > p_effective_date
    );

    RETURN v_total_cost;
END;
$$;

-- Validate BOM for circular references using recursive CTE with CYCLE detection
CREATE OR REPLACE FUNCTION mfg.fn_validate_bom_circular(
    p_part_id BIGINT
) RETURNS TABLE (
    is_valid BOOLEAN,
    message  TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO   v_count
    FROM (
        WITH RECURSIVE bom_check AS (
            SELECT b.component_part_id,
                   ARRAY[b.parent_part_id] AS path,
                   FALSE AS is_cycle
            FROM   mfg.bill_of_materials b
            WHERE  b.parent_part_id = p_part_id

            UNION ALL

            SELECT b.component_part_id,
                   bc.path || b.parent_part_id,
                   b.component_part_id = ANY(bc.path) AS is_cycle
            FROM   bom_check bc
            JOIN   mfg.bill_of_materials b ON b.parent_part_id = bc.component_part_id
            WHERE  NOT bc.is_cycle
        )
        SELECT 1 FROM bom_check WHERE is_cycle
    ) cycles;

    IF v_count > 0 THEN
        is_valid := FALSE;
        message := 'Circular reference detected in BOM for part ' || p_part_id::TEXT;
    ELSE
        is_valid := TRUE;
        message := 'BOM structure is valid';
    END IF;
    RETURN NEXT;
EXCEPTION
    WHEN OTHERS THEN
        is_valid := FALSE;
        message := 'Validation error: ' || SQLERRM;
        RETURN NEXT;
END;
$$;

-- Where-used: reverse BOM explosion using recursive CTE
-- Replaces CONNECT BY PRIOR ... + BULK COLLECT + NOCOPY
CREATE OR REPLACE FUNCTION mfg.fn_get_where_used(
    p_component_part_id BIGINT
) RETURNS TABLE (
    bom_level     INTEGER,
    part_id       BIGINT,
    part_number   VARCHAR(20),
    description   VARCHAR(100),
    qty_required  NUMERIC(12,4),
    extended_cost NUMERIC(14,4),
    bom_path      TEXT
)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE where_used AS (
        -- Anchor: direct parents
        SELECT
            1 AS bom_level,
            p.part_id,
            p.part_number,
            p.description,
            b.qty_per_assembly::NUMERIC(12,4),
            (b.qty_per_assembly * COALESCE(p.current_cost, 0))::NUMERIC(14,4) AS extended_cost,
            ' / ' || p.part_number AS bom_path
        FROM   mfg.bill_of_materials b
        JOIN   mfg.part_master p ON p.part_id = b.parent_part_id
        WHERE  b.component_part_id = p_component_part_id

        UNION ALL

        -- Recursive: parents of parents
        SELECT
            wu.bom_level + 1,
            p.part_id,
            p.part_number,
            p.description,
            b.qty_per_assembly::NUMERIC(12,4),
            (b.qty_per_assembly * COALESCE(p.current_cost, 0))::NUMERIC(14,4),
            wu.bom_path || ' / ' || p.part_number
        FROM   where_used wu
        JOIN   mfg.bill_of_materials b ON b.component_part_id = wu.part_id
        JOIN   mfg.part_master p ON p.part_id = b.parent_part_id
        WHERE  wu.bom_level < 15
    )
    SELECT wu.bom_level, wu.part_id, wu.part_number, wu.description,
           wu.qty_required, wu.extended_cost, wu.bom_path
    FROM   where_used wu
    ORDER BY wu.bom_path;
END;
$$;
