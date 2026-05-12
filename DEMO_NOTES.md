# Demo Cheat Sheet — Oracle to PostgreSQL Migration

## Setup (do this before joining the call)
- [ ] Open the repo in a browser tab: `https://github.com/tedfoley-cog/oracle-postgres-migration-demo`
- [ ] Open `dashboard/index.html` in a second tab (shows 0% progress, all "not started")

## Demo Flow
1. Show the Oracle source code — point out CONNECT BY queries in `pkg_bom_processor.sql`, autonomous transactions in `pkg_parts_inventory.sql`, DBMS_SCHEDULER job chain in `mfg_scheduler_jobs.sql`. These are the hard parts of any Oracle-to-PG migration.
2. Open a Devin session on the repo and paste the trigger prompt from the README. Devin begins analyzing the full Oracle schema.
3. Switch to the dashboard tab — as Devin works, refresh to show packages, views, triggers, and jobs moving from "not started" to "completed". The construct mapping table shows exactly how each Oracle-ism was translated.
4. When Devin opens the PR, walk through the generated PL/pgSQL — show how CONNECT BY became WITH RECURSIVE, DECODE became CASE, DBMS_SCHEDULER became pg_cron. Every migration decision is traceable.
5. Talking point: "This is the same pattern we used with a top-10 automotive OEM migrating 25,000 lines of COBOL — Devin analyzes the full codebase first, builds a semantic map, then generates correct target code. The 73% cost reduction came from eliminating manual construct-by-construct translation."
6. Talking point: "Oracle-to-PostgreSQL has the same challenge pattern — dozens of Oracle-isms embedded across packages, views, and triggers that each need a different PostgreSQL equivalent. Devin handles all of them in a single session."
