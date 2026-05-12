# Implementation Plan — Oracle to PostgreSQL Migration Demo

## What the demo proves

An automotive manufacturer running Oracle Database for manufacturing execution (MES), supply chain, and warranty systems can migrate their entire Oracle estate — PL/SQL packages, views, materialized views, triggers, scheduler jobs, and custom types — to PostgreSQL using Devin as the autonomous migration agent. Devin analyzes Oracle-specific constructs (CONNECT BY, DECODE, NVL, ROWNUM, autonomous transactions, DBMS_SCHEDULER, materialized view refresh, Oracle types), generates idiomatic PostgreSQL equivalents (recursive CTEs, COALESCE, pg_cron, pgAgent, PostgreSQL extensions), and produces a migration dashboard showing real-time progress.

## What Devin does live

Analyze the complete Oracle schema — parse every PL/SQL package, trace view dependencies, map trigger chains, reverse-engineer scheduler jobs, identify Oracle-specific SQL constructs — then generate the full PostgreSQL migration: DDL schemas, PL/pgSQL functions, PostgreSQL triggers, views, pg_cron jobs, and data loading scripts, updating the migration dashboard as each artifact is produced.

## Stack and rationale

| Component | Source | Target | Citation |
|---|---|---|---|
| PL/SQL packages | Oracle 19c | PL/pgSQL functions | [Oracle PL/SQL docs](https://docs.oracle.com/en/database/oracle/oracle-database/19/lnpls/) → [PostgreSQL PL/pgSQL docs](https://www.postgresql.org/docs/16/plpgsql.html) |
| CONNECT BY hierarchical queries | Oracle proprietary | Recursive CTEs (WITH RECURSIVE) | [PostgreSQL wiki: Oracle to Postgres](https://wiki.postgresql.org/wiki/Oracle_to_Postgres_Conversion#CONNECT_BY) |
| DECODE / NVL | Oracle functions | CASE / COALESCE | [PostgreSQL wiki: Grammar Differences](https://wiki.postgresql.org/wiki/Oracle_to_Postgres_Conversion#Grammar_Differences) |
| Sequences | Oracle CURRVAL/NEXTVAL | PostgreSQL sequences (identical syntax) | [PostgreSQL CREATE SEQUENCE](https://www.postgresql.org/docs/16/sql-createsequence.html) |
| DBMS_SCHEDULER | Oracle job scheduler | pg_cron / pgAgent | [pg_cron docs](https://github.com/citusdata/pg_cron) |
| Materialized views | Oracle REFRESH ON DEMAND/COMMIT | PostgreSQL REFRESH MATERIALIZED VIEW (CONCURRENTLY) | [PostgreSQL docs](https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html) |
| Oracle types (OBJECT, TABLE) | Oracle user-defined types | PostgreSQL composite types / domains | [PostgreSQL CREATE TYPE](https://www.postgresql.org/docs/16/sql-createtype.html) |
| SQL*Loader CTL | Oracle data loading | PostgreSQL COPY / pgloader | [pgloader docs](https://pgloader.readthedocs.io/) |
| Autonomous transactions | PRAGMA AUTONOMOUS_TRANSACTION | dblink or separate connection | [PostgreSQL wiki](https://wiki.postgresql.org/wiki/Oracle_to_Postgres_Conversion) |
| VARCHAR2 / NUMBER | Oracle data types | VARCHAR / NUMERIC | [orafce extension](https://github.com/orafce/orafce) |
| SYSDATE / SYSTIMESTAMP | Oracle date functions | CURRENT_TIMESTAMP / NOW() | Standard SQL |

## Repo layout

```
oracle-postgres-migration-demo/
├── oracle_source/                    # "Before" state — Oracle schema (10 files)
│   ├── schema/
│   │   └── mfg_schema.sql           # Tables, constraints, sequences, indexes
│   ├── packages/
│   │   ├── pkg_parts_inventory.sql  # Parts inventory management (body + spec)
│   │   ├── pkg_bom_processor.sql    # Bill of materials explosion
│   │   └── pkg_warranty_claims.sql  # Warranty claims processing
│   ├── views/
│   │   └── mfg_views.sql            # Standard and complex views
│   ├── materialized_views/
│   │   └── mfg_matviews.sql         # Materialized views with refresh schedules
│   ├── triggers/
│   │   └── mfg_triggers.sql         # BEFORE/AFTER row and statement triggers
│   ├── jobs/
│   │   └── mfg_scheduler_jobs.sql   # DBMS_SCHEDULER job definitions
│   ├── types/
│   │   └── mfg_types.sql            # Oracle OBJECT and TABLE types
│   └── data/
│       └── seed_data.sql            # Reference data INSERTs
│
├── postgres_target/                  # Empty scaffolding (Devin populates live)
│   ├── schema/     .gitkeep
│   ├── functions/  .gitkeep
│   ├── triggers/   .gitkeep
│   ├── views/      .gitkeep
│   ├── jobs/       .gitkeep
│   ├── types/      .gitkeep
│   └── data/       .gitkeep
│
├── dashboard/
│   ├── index.html                    # Migration progress dashboard
│   └── migration_state.json          # Initial state data
│
├── docs/
│   ├── IMPLEMENTATION_PLAN.md        # This file
│   ├── flowchart.html                # Interactive Mermaid diagram
│   └── flowchart.png                 # Rasterized screenshot
│
├── .github/workflows/ci.yml          # CI validation
├── README.md                         # With case studies and flowchart
└── DEMO_NOTES.md                     # Presenter cheat sheet
```

**File count:** ~18 source files + 7 .gitkeep = 25 total

## Flowchart outline

Nodes:
1. Oracle Source Database → 2. Prompt Devin →
3. Analysis Phase: Parse PL/SQL Packages, Map View Dependencies, Trace Trigger Chains, Analyze Scheduler Jobs, Identify Oracle-isms →
4. Generation Phase: Generate PostgreSQL DDL, Generate PL/pgSQL Functions, Generate PostgreSQL Triggers/Views, Generate pg_cron Jobs, Generate Data Migration Scripts →
5. Produce Migration Dashboard → 6. Open PR with All Artifacts → 7. Presenter Reviews Results

## Runtime plan

**"Appears runnable" via dashboard:** The migration dashboard loads from `dashboard/index.html` with embedded JSON showing 0% progress. During the live demo, Devin updates `migration_state.json` as it generates PostgreSQL artifacts. The dashboard shows:
- Summary cards (packages, views, triggers, jobs, LOC, migration %)
- Per-artifact migration status table
- Oracle-to-PostgreSQL construct mapping reference
- Data type conversion reference

No Oracle or PostgreSQL database is required — all source code is static SQL files.

## CI plan

- Validate Oracle SQL files exist and are non-empty
- Validate repo directory structure
- Validate dashboard HTML and JSON
- Check SQL files for basic syntax (SELECT/CREATE/DECLARE keywords present)

## Risks and unknowns

1. Oracle autonomous transactions (PRAGMA AUTONOMOUS_TRANSACTION) have no direct PostgreSQL equivalent — dblink workaround is well-documented but adds complexity
2. Oracle's empty string = NULL behavior differs from PostgreSQL — flagged in migration notes
3. CONNECT BY PRIOR syntax maps cleanly to WITH RECURSIVE but edge cases around LEVEL and SYS_CONNECT_BY_PATH need attention
4. Materialized view refresh timing differs — Oracle supports ON COMMIT refresh, PostgreSQL does not (requires trigger-based workaround or scheduled refresh)
