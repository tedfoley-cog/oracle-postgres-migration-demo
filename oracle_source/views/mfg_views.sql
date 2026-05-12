-- =============================================================================
-- Manufacturing Views — Oracle Database 19c
-- Oracle-isms: NVL, DECODE, CONNECT BY (in V_BOM_HIERARCHY),
--              ROWNUM, Oracle date arithmetic, (+) outer join syntax
-- =============================================================================

-- Current inventory position by part
CREATE OR REPLACE VIEW MFG.V_INVENTORY_POSITION AS
SELECT p.PART_ID,
       p.PART_NUMBER,
       p.DESCRIPTION,
       p.PART_TYPE,
       p.ABC_CLASS,
       NVL(SUM(it.TXN_QTY), 0) AS ON_HAND_QTY,
       p.REORDER_POINT,
       DECODE(SIGN(NVL(SUM(it.TXN_QTY), 0) - p.REORDER_POINT),
              -1, 'BELOW REORDER',
               0, 'AT REORDER',
                  'ADEQUATE') AS STOCK_STATUS,
       p.CURRENT_COST,
       NVL(SUM(it.TXN_QTY), 0) * NVL(p.CURRENT_COST, 0) AS INVENTORY_VALUE
FROM   MFG.PART_MASTER p
LEFT JOIN MFG.INVENTORY_TRANSACTIONS it ON p.PART_ID = it.PART_ID
WHERE  p.STATUS = 'ACTIVE'
GROUP BY p.PART_ID, p.PART_NUMBER, p.DESCRIPTION, p.PART_TYPE,
         p.ABC_CLASS, p.REORDER_POINT, p.CURRENT_COST;

-- Production order status with completion percentage
CREATE OR REPLACE VIEW MFG.V_PRODUCTION_STATUS AS
SELECT po.ORDER_ID,
       po.ORDER_NUMBER,
       po.PLANT_CODE,
       pl.PLANT_NAME,
       p.PART_NUMBER,
       p.DESCRIPTION AS ASSEMBLY_DESC,
       po.ORDER_QTY,
       po.COMPLETED_QTY,
       po.SCRAP_QTY,
       ROUND(NVL(po.COMPLETED_QTY, 0) / NULLIF(po.ORDER_QTY, 0) * 100, 1) AS PCT_COMPLETE,
       po.STATUS,
       po.ORDER_DATE,
       po.DUE_DATE,
       po.DUE_DATE - SYSDATE AS DAYS_UNTIL_DUE,
       DECODE(SIGN(po.DUE_DATE - SYSDATE),
              -1, 'OVERDUE',
               0, 'DUE TODAY',
                  'ON TRACK') AS SCHEDULE_STATUS,
       po.PRIORITY
FROM   MFG.PRODUCTION_ORDERS po
JOIN   MFG.PART_MASTER p ON po.ASSEMBLY_PART_ID = p.PART_ID
JOIN   MFG.PLANT_MASTER pl ON po.PLANT_CODE = pl.PLANT_CODE;

-- Supplier scorecard
CREATE OR REPLACE VIEW MFG.V_SUPPLIER_SCORECARD AS
SELECT s.SUPPLIER_ID,
       s.SUPPLIER_CODE,
       s.SUPPLIER_NAME,
       s.QUALITY_RATING,
       s.DELIVERY_RATING,
       s.DEFECT_PPM,
       NVL(qi.inspection_count, 0) AS TOTAL_INSPECTIONS,
       NVL(qi.reject_count, 0) AS TOTAL_REJECTIONS,
       ROUND(
           DECODE(NVL(qi.inspection_count, 0), 0, 100,
                  (1 - qi.reject_count / qi.inspection_count) * 100
           ), 2
       ) AS ACCEPTANCE_RATE,
       s.STATUS
FROM   MFG.SUPPLIER_MASTER s
LEFT JOIN (
    SELECT SUPPLIER_ID,
           COUNT(*) AS inspection_count,
           SUM(DECODE(DISPOSITION, 'REJECTED', 1, 0)) AS reject_count
    FROM   MFG.QUALITY_INSPECTIONS
    GROUP BY SUPPLIER_ID
) qi ON s.SUPPLIER_ID = qi.SUPPLIER_ID;

-- BOM hierarchy (uses CONNECT BY)
CREATE OR REPLACE VIEW MFG.V_BOM_HIERARCHY AS
SELECT LEVEL AS BOM_LEVEL,
       LPAD(' ', (LEVEL - 1) * 2) || p.PART_NUMBER AS INDENTED_PART,
       p.PART_ID,
       p.PART_NUMBER,
       p.DESCRIPTION,
       b.QTY_PER_ASSEMBLY,
       p.CURRENT_COST,
       b.QTY_PER_ASSEMBLY * NVL(p.CURRENT_COST, 0) AS EXTENDED_COST,
       SYS_CONNECT_BY_PATH(p.PART_NUMBER, ' > ') AS FULL_PATH
FROM   MFG.BILL_OF_MATERIALS b
JOIN   MFG.PART_MASTER p ON p.PART_ID = b.COMPONENT_PART_ID
WHERE  b.EFFECTIVITY_START <= SYSDATE
AND    NVL(b.EFFECTIVITY_END, SYSDATE + 1) > SYSDATE
START WITH b.PARENT_PART_ID IN (
    SELECT PART_ID FROM MFG.PART_MASTER WHERE PART_TYPE = 'MF'
)
CONNECT BY PRIOR b.COMPONENT_PART_ID = b.PARENT_PART_ID
       AND LEVEL <= 15;

-- Warranty claims analysis
CREATE OR REPLACE VIEW MFG.V_WARRANTY_ANALYSIS AS
SELECT wc.CLAIM_ID,
       wc.CLAIM_NUMBER,
       wc.DEALER_CODE,
       wc.VIN,
       p.PART_NUMBER,
       p.DESCRIPTION AS PART_DESC,
       DECODE(wc.WARRANTY_TYPE,
              'BW', 'Basic',
              'PT', 'Powertrain',
              'EM', 'Emissions',
              'CR', 'Corrosion') AS WARRANTY_DESC,
       wc.DEFECT_CODE,
       wc.REPAIR_DATE,
       wc.MILEAGE,
       ROUND(MONTHS_BETWEEN(wc.REPAIR_DATE, wc.SALE_DATE), 1) AS AGE_MONTHS,
       wc.SETTLEMENT_AMT,
       wc.DISPOSITION,
       wc.PROCESS_DATE
FROM   MFG.WARRANTY_CLAIMS wc
JOIN   MFG.PART_MASTER p ON wc.PART_ID = p.PART_ID;
