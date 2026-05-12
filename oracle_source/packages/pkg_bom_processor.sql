-- =============================================================================
-- PKG_BOM_PROCESSOR — Bill of Materials Explosion and Costed Rollup
-- Oracle PL/SQL Package (Spec + Body)
-- Oracle-isms: CONNECT BY PRIOR, LEVEL, SYS_CONNECT_BY_PATH, BULK COLLECT,
--              FORALL, NOCOPY, pipelined table function
-- =============================================================================

CREATE OR REPLACE PACKAGE MFG.PKG_BOM_PROCESSOR AS

    TYPE t_bom_explosion_rec IS RECORD (
        bom_level       NUMBER,
        part_id         MFG.PART_MASTER.PART_ID%TYPE,
        part_number     MFG.PART_MASTER.PART_NUMBER%TYPE,
        description     MFG.PART_MASTER.DESCRIPTION%TYPE,
        qty_required    NUMBER(12,4),
        extended_cost   NUMBER(14,4),
        bom_path        VARCHAR2(4000)
    );

    TYPE t_bom_table IS TABLE OF t_bom_explosion_rec;

    FUNCTION explode_bom(
        p_parent_part_id IN NUMBER,
        p_qty            IN NUMBER DEFAULT 1,
        p_effective_date IN DATE DEFAULT SYSDATE
    ) RETURN t_bom_table PIPELINED;

    FUNCTION get_costed_rollup(
        p_parent_part_id IN NUMBER,
        p_effective_date IN DATE DEFAULT SYSDATE
    ) RETURN NUMBER;

    PROCEDURE validate_bom_circular(
        p_part_id   IN  NUMBER,
        p_is_valid  OUT BOOLEAN,
        p_message   OUT VARCHAR2
    );

    PROCEDURE get_where_used(
        p_component_part_id IN NUMBER,
        p_results           OUT NOCOPY t_bom_table
    );

END PKG_BOM_PROCESSOR;
/

CREATE OR REPLACE PACKAGE BODY MFG.PKG_BOM_PROCESSOR AS

    -- Max BOM depth to prevent infinite recursion
    C_MAX_DEPTH CONSTANT NUMBER := 15;

    FUNCTION explode_bom(
        p_parent_part_id IN NUMBER,
        p_qty            IN NUMBER DEFAULT 1,
        p_effective_date IN DATE DEFAULT SYSDATE
    ) RETURN t_bom_table PIPELINED IS
        v_rec t_bom_explosion_rec;
    BEGIN
        -- Use CONNECT BY PRIOR for hierarchical BOM traversal
        FOR r IN (
            SELECT LEVEL AS bom_level,
                   p.PART_ID,
                   p.PART_NUMBER,
                   p.DESCRIPTION,
                   b.QTY_PER_ASSEMBLY *
                       (1 + NVL(b.SCRAP_FACTOR, 0)) * p_qty AS qty_required,
                   p.CURRENT_COST,
                   SYS_CONNECT_BY_PATH(p.PART_NUMBER, ' / ') AS bom_path
            FROM   MFG.BILL_OF_MATERIALS b
            JOIN   MFG.PART_MASTER p ON p.PART_ID = b.COMPONENT_PART_ID
            WHERE  b.EFFECTIVITY_START <= p_effective_date
            AND    NVL(b.EFFECTIVITY_END, p_effective_date + 1) > p_effective_date
            START WITH b.PARENT_PART_ID = p_parent_part_id
            CONNECT BY PRIOR b.COMPONENT_PART_ID = b.PARENT_PART_ID
                   AND LEVEL <= C_MAX_DEPTH
                   AND b.EFFECTIVITY_START <= p_effective_date
                   AND NVL(b.EFFECTIVITY_END, p_effective_date + 1) > p_effective_date
            ORDER SIBLINGS BY p.PART_NUMBER
        ) LOOP
            v_rec.bom_level     := r.bom_level;
            v_rec.part_id       := r.PART_ID;
            v_rec.part_number   := r.PART_NUMBER;
            v_rec.description   := r.DESCRIPTION;
            v_rec.qty_required  := r.qty_required;
            v_rec.extended_cost := r.qty_required * NVL(r.CURRENT_COST, 0);
            v_rec.bom_path      := r.bom_path;
            PIPE ROW(v_rec);
        END LOOP;
        RETURN;
    END explode_bom;

    FUNCTION get_costed_rollup(
        p_parent_part_id IN NUMBER,
        p_effective_date IN DATE DEFAULT SYSDATE
    ) RETURN NUMBER IS
        v_total_cost NUMBER(14,4) := 0;
    BEGIN
        -- Sum extended cost of all leaf-level components
        SELECT NVL(SUM(extended_cost), 0)
        INTO   v_total_cost
        FROM   TABLE(explode_bom(p_parent_part_id, 1, p_effective_date)) b
        WHERE  NOT EXISTS (
            SELECT 1 FROM MFG.BILL_OF_MATERIALS bom
            WHERE  bom.PARENT_PART_ID = b.part_id
            AND    bom.EFFECTIVITY_START <= p_effective_date
            AND    NVL(bom.EFFECTIVITY_END, p_effective_date + 1) > p_effective_date
        );

        RETURN v_total_cost;
    END get_costed_rollup;

    PROCEDURE validate_bom_circular(
        p_part_id   IN  NUMBER,
        p_is_valid  OUT BOOLEAN,
        p_message   OUT VARCHAR2
    ) IS
        v_count NUMBER;
    BEGIN
        -- Check for circular references using CONNECT BY with NOCYCLE
        SELECT COUNT(*)
        INTO   v_count
        FROM   MFG.BILL_OF_MATERIALS
        WHERE  CONNECT_BY_ISCYCLE = 1
        START WITH PARENT_PART_ID = p_part_id
        CONNECT BY NOCYCLE PRIOR COMPONENT_PART_ID = PARENT_PART_ID;

        IF v_count > 0 THEN
            p_is_valid := FALSE;
            p_message := 'Circular reference detected in BOM for part ' ||
                         TO_CHAR(p_part_id);
        ELSE
            p_is_valid := TRUE;
            p_message := 'BOM structure is valid';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            p_is_valid := FALSE;
            p_message := 'Validation error: ' || SQLERRM;
    END validate_bom_circular;

    PROCEDURE get_where_used(
        p_component_part_id IN NUMBER,
        p_results           OUT NOCOPY t_bom_table
    ) IS
    BEGIN
        -- Reverse BOM explosion: find all parents that use this component
        SELECT LEVEL,
               p.PART_ID,
               p.PART_NUMBER,
               p.DESCRIPTION,
               b.QTY_PER_ASSEMBLY,
               b.QTY_PER_ASSEMBLY * NVL(p.CURRENT_COST, 0),
               SYS_CONNECT_BY_PATH(p.PART_NUMBER, ' / ')
        BULK COLLECT INTO p_results
        FROM   MFG.BILL_OF_MATERIALS b
        JOIN   MFG.PART_MASTER p ON p.PART_ID = b.PARENT_PART_ID
        START WITH b.COMPONENT_PART_ID = p_component_part_id
        CONNECT BY PRIOR b.PARENT_PART_ID = b.COMPONENT_PART_ID
               AND LEVEL <= C_MAX_DEPTH;
    END get_where_used;

END PKG_BOM_PROCESSOR;
/
