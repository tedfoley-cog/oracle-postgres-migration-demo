-- =============================================================================
-- PostgreSQL Manufacturing Schema — Automotive MES / Supply Chain / Warranty
-- Migrated from Oracle Database 19c
-- PostgreSQL 16+
-- =============================================================================
-- Migration notes:
--   NUMBER(n)     → BIGINT / INTEGER
--   NUMBER(p,s)   → NUMERIC(p,s)
--   VARCHAR2(n)   → VARCHAR(n)
--   DATE          → TIMESTAMP (Oracle DATE includes time component)
--   SYSDATE       → CURRENT_TIMESTAMP
--   USER          → CURRENT_USER
--   NOCACHE       → (omitted; PG sequences cache by default)
--   MFG. prefix   → mfg. (lowercase schema)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS mfg;

-- Sequences
CREATE SEQUENCE mfg.part_seq         START WITH 100001 INCREMENT BY 1;
CREATE SEQUENCE mfg.order_seq        START WITH 500001 INCREMENT BY 1;
CREATE SEQUENCE mfg.claim_seq        START WITH 900001 INCREMENT BY 1;
CREATE SEQUENCE mfg.inspection_seq   START WITH 200001 INCREMENT BY 1;
CREATE SEQUENCE mfg.shipment_seq     START WITH 300001 INCREMENT BY 1;
CREATE SEQUENCE mfg.audit_seq        START WITH 1      INCREMENT BY 1;

-- Part Master
CREATE TABLE mfg.part_master (
    part_id            BIGINT          NOT NULL DEFAULT nextval('mfg.part_seq'),
    part_number        VARCHAR(20)     NOT NULL,
    description        VARCHAR(100),
    part_type          VARCHAR(4)      NOT NULL,
    uom                VARCHAR(6)      DEFAULT 'EA',
    weight_kg          NUMERIC(8,3),
    std_cost           NUMERIC(12,4),
    current_cost       NUMERIC(12,4),
    reorder_point      NUMERIC(10,2)   DEFAULT 0,
    reorder_qty        NUMERIC(10,2)   DEFAULT 0,
    lead_time_days     INTEGER         DEFAULT 0,
    abc_class          VARCHAR(1)      DEFAULT 'C',
    status             VARCHAR(10)     DEFAULT 'ACTIVE',
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    modified_date      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    modified_by        VARCHAR(30)     DEFAULT CURRENT_USER,
    CONSTRAINT pk_part_master PRIMARY KEY (part_id),
    CONSTRAINT uk_part_number UNIQUE (part_number),
    CONSTRAINT ck_part_type CHECK (part_type IN ('RM','PU','MF','SA')),
    CONSTRAINT ck_abc_class CHECK (abc_class IN ('A','B','C'))
);

-- Bill of Materials
CREATE TABLE mfg.bill_of_materials (
    bom_id             BIGINT          NOT NULL,
    parent_part_id     BIGINT          NOT NULL,
    component_part_id  BIGINT          NOT NULL,
    qty_per_assembly   NUMERIC(8,4)    NOT NULL,
    scrap_factor       NUMERIC(5,4)    DEFAULT 0,
    effectivity_start  TIMESTAMP       NOT NULL,
    effectivity_end    TIMESTAMP,
    item_type          VARCHAR(4)      DEFAULT 'STD',
    find_number        VARCHAR(10),
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_bom PRIMARY KEY (bom_id),
    CONSTRAINT fk_bom_parent FOREIGN KEY (parent_part_id) REFERENCES mfg.part_master(part_id),
    CONSTRAINT fk_bom_comp FOREIGN KEY (component_part_id) REFERENCES mfg.part_master(part_id)
);

-- Supplier Master
CREATE TABLE mfg.supplier_master (
    supplier_id        BIGINT          NOT NULL,
    supplier_code      VARCHAR(12)     NOT NULL,
    supplier_name      VARCHAR(80)     NOT NULL,
    contact_name       VARCHAR(60),
    address_line1      VARCHAR(60),
    address_line2      VARCHAR(60),
    city               VARCHAR(40),
    state_province     VARCHAR(30),
    postal_code        VARCHAR(15),
    country_code       VARCHAR(3)      DEFAULT 'USA',
    phone              VARCHAR(20),
    email              VARCHAR(80),
    payment_terms      VARCHAR(10)     DEFAULT 'NET30',
    currency_code      VARCHAR(3)      DEFAULT 'USD',
    quality_rating     NUMERIC(3,1),
    delivery_rating    NUMERIC(3,1),
    defect_ppm         INTEGER,
    status             VARCHAR(10)     DEFAULT 'ACTIVE',
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_supplier PRIMARY KEY (supplier_id),
    CONSTRAINT uk_supplier_code UNIQUE (supplier_code)
);

-- Production Orders
CREATE TABLE mfg.production_orders (
    order_id           BIGINT          NOT NULL DEFAULT nextval('mfg.order_seq'),
    order_number       VARCHAR(15)     NOT NULL,
    plant_code         VARCHAR(4)      NOT NULL,
    assembly_part_id   BIGINT          NOT NULL,
    order_qty          NUMERIC(10,2)   NOT NULL,
    completed_qty      NUMERIC(10,2)   DEFAULT 0,
    scrap_qty          NUMERIC(10,2)   DEFAULT 0,
    order_date         TIMESTAMP       NOT NULL,
    due_date           TIMESTAMP       NOT NULL,
    completion_date    TIMESTAMP,
    status             VARCHAR(12)     DEFAULT 'PLANNED',
    priority           SMALLINT        DEFAULT 3,
    shift_code         VARCHAR(2),
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_prod_order PRIMARY KEY (order_id),
    CONSTRAINT uk_order_number UNIQUE (order_number),
    CONSTRAINT fk_order_part FOREIGN KEY (assembly_part_id) REFERENCES mfg.part_master(part_id),
    CONSTRAINT ck_order_status CHECK (status IN ('PLANNED','RELEASED','IN_PROGRESS','COMPLETED','CANCELLED'))
);

-- Inventory Transactions
CREATE TABLE mfg.inventory_transactions (
    txn_id             BIGINT          NOT NULL,
    part_id            BIGINT          NOT NULL,
    txn_type           VARCHAR(4)      NOT NULL,
    txn_qty            NUMERIC(10,2)   NOT NULL,
    txn_cost           NUMERIC(12,4),
    warehouse_code     VARCHAR(6),
    location_code      VARCHAR(10),
    reference_type     VARCHAR(4),
    reference_id       BIGINT,
    txn_date           TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    created_by         VARCHAR(30)     DEFAULT CURRENT_USER,
    CONSTRAINT pk_inv_txn PRIMARY KEY (txn_id),
    CONSTRAINT fk_inv_part FOREIGN KEY (part_id) REFERENCES mfg.part_master(part_id),
    CONSTRAINT ck_txn_type CHECK (txn_type IN ('RC','IS','AJ','TR'))
);

-- Warranty Claims
CREATE TABLE mfg.warranty_claims (
    claim_id           BIGINT          NOT NULL DEFAULT nextval('mfg.claim_seq'),
    claim_number       VARCHAR(15)     NOT NULL,
    dealer_code        VARCHAR(8)      NOT NULL,
    vin                VARCHAR(17)     NOT NULL,
    part_id            BIGINT          NOT NULL,
    warranty_type      VARCHAR(2)      NOT NULL,
    defect_code        VARCHAR(6),
    repair_date        TIMESTAMP,
    mileage            INTEGER,
    sale_date          TIMESTAMP,
    labor_hours        NUMERIC(6,2),
    labor_rate         NUMERIC(8,2),
    parts_cost         NUMERIC(10,2),
    sublet_cost        NUMERIC(10,2),
    settlement_amt     NUMERIC(12,2),
    disposition        VARCHAR(12)     DEFAULT 'PENDING',
    process_date       TIMESTAMP,
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_warranty PRIMARY KEY (claim_id),
    CONSTRAINT uk_claim_number UNIQUE (claim_number),
    CONSTRAINT fk_claim_part FOREIGN KEY (part_id) REFERENCES mfg.part_master(part_id),
    CONSTRAINT ck_warranty_type CHECK (warranty_type IN ('BW','PT','EM','CR'))
);

-- Quality Inspections
CREATE TABLE mfg.quality_inspections (
    inspection_id      BIGINT          NOT NULL DEFAULT nextval('mfg.inspection_seq'),
    part_id            BIGINT          NOT NULL,
    supplier_id        BIGINT,
    lot_number         VARCHAR(20),
    sample_size        INTEGER,
    defects_found      INTEGER         DEFAULT 0,
    disposition        VARCHAR(12)     DEFAULT 'PENDING',
    inspector_id       VARCHAR(20),
    inspection_date    TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    measurement_1      NUMERIC(9,4),
    measurement_2      NUMERIC(9,4),
    measurement_3      NUMERIC(9,4),
    upper_spec_limit   NUMERIC(9,4),
    lower_spec_limit   NUMERIC(9,4),
    created_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_inspection PRIMARY KEY (inspection_id),
    CONSTRAINT fk_insp_part FOREIGN KEY (part_id) REFERENCES mfg.part_master(part_id),
    CONSTRAINT fk_insp_supplier FOREIGN KEY (supplier_id) REFERENCES mfg.supplier_master(supplier_id)
);

-- Plant Master
CREATE TABLE mfg.plant_master (
    plant_code         VARCHAR(4)      NOT NULL,
    plant_name         VARCHAR(60)     NOT NULL,
    city               VARCHAR(40),
    state_province     VARCHAR(30),
    country_code       VARCHAR(3)      DEFAULT 'USA',
    daily_capacity     INTEGER,
    shift_count        SMALLINT        DEFAULT 2,
    status             VARCHAR(10)     DEFAULT 'ACTIVE',
    CONSTRAINT pk_plant PRIMARY KEY (plant_code)
);

-- Audit Trail
CREATE TABLE mfg.audit_trail (
    audit_id           BIGINT          NOT NULL DEFAULT nextval('mfg.audit_seq'),
    table_name         VARCHAR(30)     NOT NULL,
    operation          VARCHAR(10)     NOT NULL,
    primary_key_value  VARCHAR(50),
    column_name        VARCHAR(30),
    old_value          TEXT,
    new_value          TEXT,
    changed_by         VARCHAR(30)     DEFAULT CURRENT_USER,
    changed_date       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_audit PRIMARY KEY (audit_id)
);

-- Indexes
CREATE INDEX idx_bom_parent ON mfg.bill_of_materials (parent_part_id);
CREATE INDEX idx_bom_comp ON mfg.bill_of_materials (component_part_id);
CREATE INDEX idx_inv_txn_part ON mfg.inventory_transactions (part_id, txn_date);
CREATE INDEX idx_warranty_vin ON mfg.warranty_claims (vin);
CREATE INDEX idx_warranty_part ON mfg.warranty_claims (part_id);
CREATE INDEX idx_insp_part ON mfg.quality_inspections (part_id);
CREATE INDEX idx_audit_table ON mfg.audit_trail (table_name, changed_date);
CREATE INDEX idx_prodord_status ON mfg.production_orders (status, due_date);
