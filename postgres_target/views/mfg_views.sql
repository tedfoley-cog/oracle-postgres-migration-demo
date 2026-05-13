-- =============================================================================
-- PostgreSQL Views (Standard + Materialized)
-- Migrated from Oracle Database 19c
-- Migration notes:
--   NVL(a,b)                  → COALESCE(a,b)
--   DECODE(a,b,c,d)           → CASE WHEN a = b THEN c ELSE d END
--   SYSDATE                   → CURRENT_TIMESTAMP
--   CONNECT BY / LEVEL / SYS_CONNECT_BY_PATH → WITH RECURSIVE CTE
--   MONTHS_BETWEEN(a,b)       → EXTRACT(EPOCH FROM AGE(a,b)) / 2592000
--   TRUNC(SYSDATE,'YYYY')     → DATE_TRUNC('year', CURRENT_TIMESTAMP)
--   BUILD IMMEDIATE           → (omitted; PG matviews populate on creation)
--   ENABLE QUERY REWRITE      → (omitted; PG has no equivalent)
--   REFRESH ON DEMAND         → managed via pg_cron
-- =============================================================================

-- =====================
-- STANDARD VIEWS
-- =====================

-- Current inventory position by part
CREATE OR REPLACE VIEW mfg.v_inventory_position AS
SELECT p.part_id,
       p.part_number,
       p.description,
       p.part_type,
       p.abc_class,
       COALESCE(SUM(it.txn_qty), 0) AS on_hand_qty,
       p.reorder_point,
       CASE
           WHEN SIGN(COALESCE(SUM(it.txn_qty), 0) - p.reorder_point) = -1 THEN 'BELOW REORDER'
           WHEN SIGN(COALESCE(SUM(it.txn_qty), 0) - p.reorder_point) = 0  THEN 'AT REORDER'
           ELSE 'ADEQUATE'
       END AS stock_status,
       p.current_cost,
       COALESCE(SUM(it.txn_qty), 0) * COALESCE(p.current_cost, 0) AS inventory_value
FROM   mfg.part_master p
LEFT JOIN mfg.inventory_transactions it ON p.part_id = it.part_id
WHERE  p.status = 'ACTIVE'
GROUP BY p.part_id, p.part_number, p.description, p.part_type,
         p.abc_class, p.reorder_point, p.current_cost;

-- Production order status with completion percentage
CREATE OR REPLACE VIEW mfg.v_production_status AS
SELECT po.order_id,
       po.order_number,
       po.plant_code,
       pl.plant_name,
       p.part_number,
       p.description AS assembly_desc,
       po.order_qty,
       po.completed_qty,
       po.scrap_qty,
       ROUND(COALESCE(po.completed_qty, 0) / NULLIF(po.order_qty, 0) * 100, 1) AS pct_complete,
       po.status,
       po.order_date,
       po.due_date,
       EXTRACT(EPOCH FROM (po.due_date - CURRENT_TIMESTAMP)) / 86400 AS days_until_due,
       CASE
           WHEN SIGN(EXTRACT(EPOCH FROM (po.due_date - CURRENT_TIMESTAMP))) < 0 THEN 'OVERDUE'
           WHEN EXTRACT(EPOCH FROM (po.due_date - CURRENT_TIMESTAMP)) < 86400   THEN 'DUE TODAY'
           ELSE 'ON TRACK'
       END AS schedule_status,
       po.priority
FROM   mfg.production_orders po
JOIN   mfg.part_master p ON po.assembly_part_id = p.part_id
JOIN   mfg.plant_master pl ON po.plant_code = pl.plant_code;

-- Supplier scorecard
CREATE OR REPLACE VIEW mfg.v_supplier_scorecard AS
SELECT s.supplier_id,
       s.supplier_code,
       s.supplier_name,
       s.quality_rating,
       s.delivery_rating,
       s.defect_ppm,
       COALESCE(qi.inspection_count, 0) AS total_inspections,
       COALESCE(qi.reject_count, 0) AS total_rejections,
       ROUND(
           CASE WHEN COALESCE(qi.inspection_count, 0) = 0 THEN 100
                ELSE (1 - qi.reject_count::NUMERIC / qi.inspection_count) * 100
           END, 2
       ) AS acceptance_rate,
       s.status
FROM   mfg.supplier_master s
LEFT JOIN (
    SELECT supplier_id,
           COUNT(*) AS inspection_count,
           SUM(CASE WHEN disposition = 'REJECTED' THEN 1 ELSE 0 END) AS reject_count
    FROM   mfg.quality_inspections
    GROUP BY supplier_id
) qi ON s.supplier_id = qi.supplier_id;

-- BOM hierarchy using WITH RECURSIVE (replaces CONNECT BY PRIOR)
CREATE OR REPLACE VIEW mfg.v_bom_hierarchy AS
WITH RECURSIVE bom_tree AS (
    -- Anchor: top-level manufactured parts
    SELECT
        1 AS bom_level,
        p.part_id,
        p.part_number,
        p.description,
        b.qty_per_assembly,
        p.current_cost,
        (b.qty_per_assembly * COALESCE(p.current_cost, 0)) AS extended_cost,
        ' > ' || p.part_number AS full_path,
        b.parent_part_id
    FROM   mfg.bill_of_materials b
    JOIN   mfg.part_master p ON p.part_id = b.component_part_id
    WHERE  b.effectivity_start <= CURRENT_TIMESTAMP
    AND    COALESCE(b.effectivity_end, CURRENT_TIMESTAMP + INTERVAL '1 day') > CURRENT_TIMESTAMP
    AND    b.parent_part_id IN (
        SELECT part_id FROM mfg.part_master WHERE part_type = 'MF'
    )

    UNION ALL

    -- Recursive: children of children
    SELECT
        bt.bom_level + 1,
        p.part_id,
        p.part_number,
        p.description,
        b.qty_per_assembly,
        p.current_cost,
        (b.qty_per_assembly * COALESCE(p.current_cost, 0)),
        bt.full_path || ' > ' || p.part_number,
        b.parent_part_id
    FROM   bom_tree bt
    JOIN   mfg.bill_of_materials b ON b.parent_part_id = bt.part_id
    JOIN   mfg.part_master p ON p.part_id = b.component_part_id
    WHERE  bt.bom_level < 15
    AND    b.effectivity_start <= CURRENT_TIMESTAMP
    AND    COALESCE(b.effectivity_end, CURRENT_TIMESTAMP + INTERVAL '1 day') > CURRENT_TIMESTAMP
)
SELECT bom_level,
       LPAD(' ', (bom_level - 1) * 2) || part_number AS indented_part,
       part_id,
       part_number,
       description,
       qty_per_assembly,
       current_cost,
       extended_cost,
       full_path
FROM   bom_tree;

-- Warranty claims analysis
-- Oracle DECODE → CASE, MONTHS_BETWEEN → EXTRACT/AGE
CREATE OR REPLACE VIEW mfg.v_warranty_analysis AS
SELECT wc.claim_id,
       wc.claim_number,
       wc.dealer_code,
       wc.vin,
       p.part_number,
       p.description AS part_desc,
       CASE wc.warranty_type
           WHEN 'BW' THEN 'Basic'
           WHEN 'PT' THEN 'Powertrain'
           WHEN 'EM' THEN 'Emissions'
           WHEN 'CR' THEN 'Corrosion'
       END AS warranty_desc,
       wc.defect_code,
       wc.repair_date,
       wc.mileage,
       ROUND(EXTRACT(EPOCH FROM AGE(wc.repair_date, wc.sale_date)) / 2592000.0, 1) AS age_months,
       wc.settlement_amt,
       wc.disposition,
       wc.process_date
FROM   mfg.warranty_claims wc
JOIN   mfg.part_master p ON wc.part_id = p.part_id;

-- ==============================
-- MATERIALIZED VIEWS
-- ==============================

-- Inventory valuation summary by ABC class (refreshed nightly via pg_cron)
CREATE MATERIALIZED VIEW mfg.mv_inventory_valuation AS
SELECT p.abc_class,
       p.part_type,
       COUNT(DISTINCT p.part_id) AS part_count,
       COALESCE(SUM(inv.on_hand), 0) AS total_on_hand,
       COALESCE(SUM(inv.on_hand * p.current_cost), 0) AS total_value,
       COALESCE(AVG(p.current_cost), 0) AS avg_unit_cost
FROM   mfg.part_master p
LEFT JOIN (
    SELECT part_id, SUM(txn_qty) AS on_hand
    FROM   mfg.inventory_transactions
    GROUP BY part_id
) inv ON p.part_id = inv.part_id
WHERE  p.status = 'ACTIVE'
GROUP BY p.abc_class, p.part_type;

CREATE UNIQUE INDEX idx_mv_inv_val ON mfg.mv_inventory_valuation (abc_class, part_type);

-- Supplier performance dashboard (refreshed weekly via pg_cron)
CREATE MATERIALIZED VIEW mfg.mv_supplier_performance AS
SELECT s.supplier_id,
       s.supplier_code,
       s.supplier_name,
       COUNT(qi.inspection_id) AS inspections_ytd,
       SUM(CASE WHEN qi.disposition = 'ACCEPTED' THEN 1 ELSE 0 END) AS accepted_count,
       SUM(CASE WHEN qi.disposition = 'REJECTED' THEN 1 ELSE 0 END) AS rejected_count,
       ROUND(
           SUM(CASE WHEN qi.disposition = 'ACCEPTED' THEN 1 ELSE 0 END)::NUMERIC /
           GREATEST(COUNT(qi.inspection_id), 1) * 100, 2
       ) AS acceptance_rate_pct,
       COALESCE(AVG(qi.defects_found), 0) AS avg_defects_per_lot,
       s.defect_ppm,
       s.quality_rating,
       s.delivery_rating
FROM   mfg.supplier_master s
LEFT JOIN mfg.quality_inspections qi
       ON s.supplier_id = qi.supplier_id
       AND qi.inspection_date >= DATE_TRUNC('year', CURRENT_TIMESTAMP)
GROUP BY s.supplier_id, s.supplier_code, s.supplier_name,
         s.defect_ppm, s.quality_rating, s.delivery_rating;

CREATE UNIQUE INDEX idx_mv_supp_perf ON mfg.mv_supplier_performance (supplier_id);

-- Warranty cost by defect code (refreshed monthly via pg_cron)
CREATE MATERIALIZED VIEW mfg.mv_warranty_cost_analysis AS
SELECT wc.defect_code,
       CASE wc.warranty_type
           WHEN 'BW' THEN 'Basic'
           WHEN 'PT' THEN 'Powertrain'
           WHEN 'EM' THEN 'Emissions'
           WHEN 'CR' THEN 'Corrosion'
       END AS warranty_desc,
       COUNT(*) AS claim_count,
       SUM(COALESCE(wc.settlement_amt, 0)) AS total_settlement,
       ROUND(AVG(COALESCE(wc.settlement_amt, 0)), 2) AS avg_settlement,
       MIN(wc.repair_date) AS first_occurrence,
       MAX(wc.repair_date) AS last_occurrence,
       ROUND(AVG(COALESCE(wc.mileage, 0)), 0) AS avg_mileage
FROM   mfg.warranty_claims wc
WHERE  wc.disposition IN ('APPROVED', 'REJECTED')
GROUP BY wc.defect_code, wc.warranty_type;

CREATE UNIQUE INDEX idx_mv_warr_cost ON mfg.mv_warranty_cost_analysis (defect_code, warranty_desc);

-- Production order backlog (refreshed daily via pg_cron)
CREATE MATERIALIZED VIEW mfg.mv_production_backlog AS
SELECT po.plant_code,
       pl.plant_name,
       po.status,
       COUNT(*) AS order_count,
       SUM(po.order_qty) AS total_qty,
       SUM(po.order_qty - COALESCE(po.completed_qty, 0)) AS remaining_qty,
       MIN(po.due_date) AS earliest_due,
       SUM(CASE WHEN po.due_date < CURRENT_TIMESTAMP AND po.status != 'COMPLETED'
                THEN 1 ELSE 0 END) AS overdue_count
FROM   mfg.production_orders po
JOIN   mfg.plant_master pl ON po.plant_code = pl.plant_code
WHERE  po.status NOT IN ('COMPLETED', 'CANCELLED')
GROUP BY po.plant_code, pl.plant_name, po.status;

CREATE UNIQUE INDEX idx_mv_prod_backlog ON mfg.mv_production_backlog (plant_code, status);
