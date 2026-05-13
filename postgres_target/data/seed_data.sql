-- =============================================================================
-- Reference / Seed Data — PostgreSQL
-- Migrated from Oracle Database 19c
-- Migration notes:
--   DATE '2024-01-01'       → TIMESTAMP '2024-01-01' (Oracle DATE has time)
--   MFG. prefix             → mfg. (lowercase)
--   Implicit SYSDATE cols   → handled by DEFAULT CURRENT_TIMESTAMP in DDL
-- =============================================================================

-- Plant Master
INSERT INTO mfg.plant_master VALUES ('DT01', 'Detroit Assembly Plant',      'Detroit',     'MI', 'USA', 1200, 3, 'ACTIVE');
INSERT INTO mfg.plant_master VALUES ('KY02', 'Georgetown Assembly Plant',   'Georgetown',  'KY', 'USA', 2000, 2, 'ACTIVE');
INSERT INTO mfg.plant_master VALUES ('TX03', 'San Antonio Assembly Plant',  'San Antonio', 'TX', 'USA', 1500, 2, 'ACTIVE');
INSERT INTO mfg.plant_master VALUES ('ON04', 'Oshawa Assembly Plant',       'Oshawa',      'ON', 'CAN', 800,  2, 'ACTIVE');

-- Sample Parts
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (1, 'ASM-VEH-001', 'Vehicle Assembly - Sedan',      'MF', 'EA', 1450.0,  28500.00, 28750.00, 0,    0,   0, 'A');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (2, 'ASM-ENG-001', 'Engine Assembly - 2.5L I4',     'SA', 'EA', 180.5,   4200.00,  4350.00,  50,   100, 14, 'A');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (3, 'ASM-TRN-001', 'Transmission Assembly - 8-Spd', 'SA', 'EA', 95.0,    3100.00,  3200.00,  30,   60,  21, 'A');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (4, 'PUR-BRK-001', 'Brake Rotor - Front',           'PU', 'EA', 8.5,     45.00,    47.50,    200,  500, 7,  'B');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (5, 'PUR-BRK-002', 'Brake Pad Set - Front',         'PU', 'SET',2.1,     32.00,    33.75,    300,  600, 5,  'B');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (6, 'RAW-STL-001', 'Steel Sheet - Cold Rolled',     'RM', 'KG', 1.0,     1.20,     1.35,     5000, 10000,10, 'A');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (7, 'RAW-ALU-001', 'Aluminum Ingot - 6061',         'RM', 'KG', 1.0,     2.80,     3.10,     3000, 8000, 14, 'A');
INSERT INTO mfg.part_master (part_id, part_number, description, part_type, uom, weight_kg, std_cost, current_cost, reorder_point, reorder_qty, lead_time_days, abc_class)
VALUES (8, 'PUR-ELC-001', 'Wiring Harness - Main',         'PU', 'EA', 12.0,    285.00,   295.00,   100,  200, 10, 'B');

-- Sample BOM (Vehicle Assembly)
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (1, 1, 2, 1, 0.005, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (2, 1, 3, 1, 0.003, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (3, 1, 4, 2, 0.02, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (4, 1, 5, 2, 0.01, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (5, 1, 8, 1, 0.01, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (6, 2, 6, 120, 0.05, TIMESTAMP '2024-01-01', 'STD');
INSERT INTO mfg.bill_of_materials (bom_id, parent_part_id, component_part_id, qty_per_assembly, scrap_factor, effectivity_start, item_type)
VALUES (7, 2, 7, 45, 0.03, TIMESTAMP '2024-01-01', 'STD');

-- Sample Suppliers
INSERT INTO mfg.supplier_master (supplier_id, supplier_code, supplier_name, contact_name, city, state_province, country_code, payment_terms, quality_rating, delivery_rating, defect_ppm)
VALUES (1, 'SUP-BRK-01', 'Midwest Brake Systems',    'J. Henderson', 'Dayton',    'OH', 'USA', 'NET30', 9.2, 8.8, 120);
INSERT INTO mfg.supplier_master (supplier_id, supplier_code, supplier_name, contact_name, city, state_province, country_code, payment_terms, quality_rating, delivery_rating, defect_ppm)
VALUES (2, 'SUP-STL-01', 'Great Lakes Steel Corp',   'M. Kowalski',  'Gary',      'IN', 'USA', 'NET45', 8.5, 9.1, 85);
INSERT INTO mfg.supplier_master (supplier_id, supplier_code, supplier_name, contact_name, city, state_province, country_code, payment_terms, quality_rating, delivery_rating, defect_ppm)
VALUES (3, 'SUP-ELC-01', 'Pacific Wire & Cable Inc', 'T. Nakamura',  'Fremont',   'CA', 'USA', 'NET30', 9.0, 8.5, 150);
INSERT INTO mfg.supplier_master (supplier_id, supplier_code, supplier_name, contact_name, city, state_province, country_code, payment_terms, quality_rating, delivery_rating, defect_ppm)
VALUES (4, 'SUP-ALU-01', 'Northern Aluminum Ltd',    'R. Tremblay',  'Montreal',  'QC', 'CAN', 'NET60', 8.8, 7.9, 200);

COMMIT;
