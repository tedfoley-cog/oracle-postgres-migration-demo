-- =============================================================================
-- User-Defined Types — Oracle Database 19c
-- Oracle-isms: CREATE TYPE AS OBJECT, TABLE OF, MEMBER FUNCTION,
--              MAP MEMBER FUNCTION, constructor overloading
-- =============================================================================

-- Address type (reusable across supplier, plant, dealer)
CREATE OR REPLACE TYPE MFG.T_ADDRESS AS OBJECT (
    ADDRESS_LINE1   VARCHAR2(60),
    ADDRESS_LINE2   VARCHAR2(60),
    CITY            VARCHAR2(40),
    STATE_PROVINCE  VARCHAR2(30),
    POSTAL_CODE     VARCHAR2(15),
    COUNTRY_CODE    VARCHAR2(3),

    MEMBER FUNCTION get_full_address RETURN VARCHAR2,
    MAP MEMBER FUNCTION get_sort_key RETURN VARCHAR2
);
/

CREATE OR REPLACE TYPE BODY MFG.T_ADDRESS AS
    MEMBER FUNCTION get_full_address RETURN VARCHAR2 IS
    BEGIN
        RETURN ADDRESS_LINE1 ||
               DECODE(ADDRESS_LINE2, NULL, '', CHR(10) || ADDRESS_LINE2) ||
               CHR(10) || CITY || ', ' || STATE_PROVINCE ||
               ' ' || POSTAL_CODE || CHR(10) || COUNTRY_CODE;
    END;

    MAP MEMBER FUNCTION get_sort_key RETURN VARCHAR2 IS
    BEGIN
        RETURN COUNTRY_CODE || POSTAL_CODE;
    END;
END;
/

-- Measurement result type (quality inspections)
CREATE OR REPLACE TYPE MFG.T_MEASUREMENT AS OBJECT (
    MEASUREMENT_VALUE  NUMBER(9,4),
    UPPER_SPEC         NUMBER(9,4),
    LOWER_SPEC         NUMBER(9,4),
    UOM                VARCHAR2(10),

    MEMBER FUNCTION is_in_spec RETURN NUMBER,
    MEMBER FUNCTION get_deviation RETURN NUMBER
);
/

CREATE OR REPLACE TYPE BODY MFG.T_MEASUREMENT AS
    MEMBER FUNCTION is_in_spec RETURN NUMBER IS
    BEGIN
        IF MEASUREMENT_VALUE >= LOWER_SPEC
           AND MEASUREMENT_VALUE <= UPPER_SPEC THEN
            RETURN 1;
        ELSE
            RETURN 0;
        END IF;
    END;

    MEMBER FUNCTION get_deviation RETURN NUMBER IS
        v_target NUMBER;
    BEGIN
        v_target := (UPPER_SPEC + LOWER_SPEC) / 2;
        RETURN MEASUREMENT_VALUE - v_target;
    END;
END;
/

-- Collection types
CREATE OR REPLACE TYPE MFG.T_NUMBER_LIST AS TABLE OF NUMBER;
/

CREATE OR REPLACE TYPE MFG.T_VARCHAR_LIST AS TABLE OF VARCHAR2(100);
/

-- BOM component record type (used in pipelined functions)
CREATE OR REPLACE TYPE MFG.T_BOM_COMPONENT AS OBJECT (
    BOM_LEVEL       NUMBER,
    PART_ID         NUMBER(12),
    PART_NUMBER     VARCHAR2(20),
    DESCRIPTION     VARCHAR2(100),
    QTY_REQUIRED    NUMBER(12,4),
    EXTENDED_COST   NUMBER(14,4),
    BOM_PATH        VARCHAR2(4000)
);
/

CREATE OR REPLACE TYPE MFG.T_BOM_COMPONENT_TABLE AS TABLE OF MFG.T_BOM_COMPONENT;
/
