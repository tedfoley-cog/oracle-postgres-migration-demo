-- =============================================================================
-- PostgreSQL Composite Types — Migrated from Oracle Object Types
-- Migration notes:
--   CREATE TYPE AS OBJECT  → CREATE TYPE AS (composite)
--   MEMBER FUNCTION        → Standalone function accepting the type
--   MAP MEMBER FUNCTION    → Standalone function returning sort key
--   TABLE OF               → Array type or RETURNS SETOF
-- =============================================================================

-- Address composite type (replaces Oracle T_ADDRESS object type)
CREATE TYPE mfg.t_address AS (
    address_line1   VARCHAR(60),
    address_line2   VARCHAR(60),
    city            VARCHAR(40),
    state_province  VARCHAR(30),
    postal_code     VARCHAR(15),
    country_code    VARCHAR(3)
);

-- Standalone function replacing T_ADDRESS.get_full_address member function
-- Oracle DECODE(ADDRESS_LINE2, NULL, '', ...) → CASE WHEN ... IS NULL
CREATE OR REPLACE FUNCTION mfg.t_address_get_full_address(addr mfg.t_address)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN (addr).address_line1 ||
           CASE WHEN (addr).address_line2 IS NULL THEN ''
                ELSE CHR(10) || (addr).address_line2
           END ||
           CHR(10) || (addr).city || ', ' || (addr).state_province ||
           ' ' || (addr).postal_code || CHR(10) || (addr).country_code;
END;
$$;

-- Standalone function replacing T_ADDRESS.get_sort_key map member function
CREATE OR REPLACE FUNCTION mfg.t_address_get_sort_key(addr mfg.t_address)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN (addr).country_code || (addr).postal_code;
END;
$$;

-- Measurement composite type (replaces Oracle T_MEASUREMENT object type)
CREATE TYPE mfg.t_measurement AS (
    measurement_value  NUMERIC(9,4),
    upper_spec         NUMERIC(9,4),
    lower_spec         NUMERIC(9,4),
    uom                VARCHAR(10)
);

-- Standalone function replacing T_MEASUREMENT.is_in_spec member function
CREATE OR REPLACE FUNCTION mfg.t_measurement_is_in_spec(m mfg.t_measurement)
RETURNS INTEGER
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF (m).measurement_value >= (m).lower_spec
       AND (m).measurement_value <= (m).upper_spec THEN
        RETURN 1;
    ELSE
        RETURN 0;
    END IF;
END;
$$;

-- Standalone function replacing T_MEASUREMENT.get_deviation member function
CREATE OR REPLACE FUNCTION mfg.t_measurement_get_deviation(m mfg.t_measurement)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_target NUMERIC;
BEGIN
    v_target := ((m).upper_spec + (m).lower_spec) / 2;
    RETURN (m).measurement_value - v_target;
END;
$$;

-- BOM component composite type (replaces Oracle T_BOM_COMPONENT object type)
-- Used as return type for set-returning functions (replaces PIPELINED TABLE)
CREATE TYPE mfg.t_bom_component AS (
    bom_level       INTEGER,
    part_id         BIGINT,
    part_number     VARCHAR(20),
    description     VARCHAR(100),
    qty_required    NUMERIC(12,4),
    extended_cost   NUMERIC(14,4),
    bom_path        TEXT
);
