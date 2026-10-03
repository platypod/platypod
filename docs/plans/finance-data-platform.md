# Personal finance data platform — plan (draft, two alternatives)

Status: **draft for decision**, 2026-10-02. Nothing is implemented.

Goal: dashboards over personal finance data (payslips first; then bank
statements, stocks, history + forecasts) on the existing Grafana, built as
instrumented, contract-bound pipelines on Postgres.

Fixed decisions (both alternatives):

- Storage: **PostgreSQL**, medallion layout **bronze / silver / gold**.
- Every pipeline is instrumented with **OpenTelemetry** and **OpenLineage**,
  whatever runs it (Kestra, Airflow, cron, a shell). No lineage backend yet; the
  events must be captured now and replayable later.
- Every dataset beyond bronze is bound to an **ODCS** data contract, and the
  contracts are the **single source of truth for everything declarative**
  (schema, types, keys, quality rules, SLAs, classification, ownership). DDL,
  docs and any tool config are *generated* from them, never edited. The only other
  hand-written artifact is the transformation logic (the `SELECT`s): a contract
  says *what* a dataset is, never *how* it is computed.
- Transformation: **dbt-core on Postgres, in "contract-owned DDL" mode** — the
  contract creates the tables, dbt only fills them (incremental/view models).
  Validated by a hands-on spike on 2026-10-02 (see [section 6](#6-dbt--odcs-integration-validated-by-spike)).
- Backup encryption: **deferred** (see [Deferred](#deferred--risks)).

The only open choice is the orchestrator: **A — light/native (k8s CronJobs)** or
**B — robust (Kestra)**. Everything else is shared, so A → B is a re-plumbing, not
a rewrite.

---

## Phase 0 status (2026-10-02) — implemented, verified locally, not deployed

- `finance-pipelines/`: wrapper (OTel traces/metrics/logs, OpenLineage → `ops`,
  ODCS gate), `pp` CLI (`generate [--check]`, `lint`, `migrate`, `test`, `run`),
  heartbeat pipeline, dbt project, Dockerfile, Makefile, tests (8 passing: unit +
  integration against a throwaway Postgres 17; telemetry verified against a local
  OTel collector; the image runs the pipeline as non-root).
- `stack/src/finance/` + `apps/base/values/finance.yaml` + Flux wiring
  (HelmRelease, kustomization, `valuesFrom` in all HelmReleases): renders and
  dry-runs clean; **disabled by default**; guard fails on placeholder credentials.
- Nothing is committed, pushed or deployed. See `stack/src/finance/README.md` for
  the enabling checklist (image publish, sops credentials, prod local db volume).
- Open: Grafana datasource access model (OSS has no per-datasource permissions);
  `pg_dump` backup (the `localDb` backup is a file-level `tar` of the live data dir);
  Flux ImagePolicy; ODCS-schema evolution (create-only DDL); `dbt-ol` events are
  stored locally but not forwarded to `OPENLINEAGE_URL` (replay tool TBD);
  gold-as-view under an enforced contract still untested.

## Deployment status (2026-10-03)

- **Prod: enabled and run.** `finance-pipelines` is its own repo (github.com/platypod/finance-pipelines, public) with
  CI (tests; multi-arch image to GHCR on a `vX.Y.Z` tag; `v0.1.0` published). The finance module, the publication
  path (gateway pipeline, Mimir tenant `finance`, Grafana datasource + dashboard) and the credentials are live; a
  first run ingested all 79 payslips and published 2243 points for owner `pittinic`. Verified on prod: tenant data,
  isolation through the prod label proxy (other user: 0 series), nothing in the `anonymous` tenant.
  **Not verified:** the Grafana UI login path through the live scope shim.
- **Local: disabled** (the overlay forces `finance.publish.enable: false`; the local cluster is not running).
- Corrections found while doing it: the Synology exports `homes` only to the laptops, so the payslip archive is
  mirrored into the apps share (`make sync-payslips`); a global `*.sql` gitignore had silently dropped the dbt models
  and migrations (caught by CI on a clean checkout).
- Still open: Flux image automation for the image; alerting on failed backups/runs; dump encryption (deferred);
  a documented Grafana login test on prod.

## Access model (revised 2026-10-03) and backups (decided 2026-10-02)

- **Revision, 2026-10-03: payslips go in the *shared* Grafana**, isolated per user by the Jellyfin mechanism
  (`owner` label + scope shim + label proxy). The pipelines publish `finance.payslip.*` gauges (historical
  timestamps) to a dedicated `finance` Mimir tenant with its own limits; verified end to end locally on the real
  archive. Admins see all owners by design. Details, caveats and the purge runbook: `stack/src/finance/README.md`.
  The dedicated Grafana below remains as an optional, off-by-default alternative.

- **(2026-10-02, now optional) Grafana: a dedicated instance** (`finance-grafana`) behind Authelia forward-auth
  (`finance_user`/`admins`) with OIDC strict role mapping and a `gold`-only DB role. The shared
  Grafana never holds finance credentials. Rationale and layers: `stack/src/finance/README.md`.
- **Backups: nightly `pg_dump -Fc`** to the NFS apps share (verified readable, 14 days), plus the
  generic `localDb` tar as a fallback. Restore verified end to end. Payslip PDFs remain the
  re-derivable source of truth. **Encryption still deferred**; off-box copy and failure alerting
  not done.

## Phase 1 status (2026-10-02) — payslips implemented, verified locally, not deployed

- All **79** payslips (2020-02 → 2026-08, no gaps) parse clean: 64 + 10 text, 5 OCR'd.
  Correction to the earlier inspection: the PDFs are **not** all text-extractable; 5 are
  print-to-PDF without a text layer, hence OCR (tesseract) in the pipeline and image.
- Two layouts, not three (the 2020-23 and 2024 files are both Silae). Multi-page payslips
  repeat headers and continue the table; the parsers handle both.
- Bronze/silver/gold + 6 ODCS contracts with reconciliation, no-gap and line-sum rules;
  gold: `income_monthly`, `contributions_monthly`. Year-to-date gross recomputed from the
  months matches the printed one for every payslip that prints it (74/74).
- Tests: parser unit tests (synthetic geometry), pipeline integration on synthetic data
  (review path, gap detection, idempotency, lineage), optional real-corpus test (passes).
- `dashboards/payslips.json` verified on Grafana 11.3 against the read-only role.
- Chart: payslips CronJob + read-only NFS volume, **off by default**; image is ~1 GB
  (dbt + datacontract-cli dominate) — slim later if it matters.
- Open: the 5 OCR'd months lack
  some totals fields; `prime de partage`/`indemnités non soumises` categorisation.

## 1. Shared foundation

### 1.1 Principle: instrumentation lives in the job, not in the orchestrator

If OTel/OpenLineage were provided by the orchestrator, switching (or running a
plain script) would lose it. So a small shared Python library — working name
`platypod_pipeline`, in a new custom-image dir (like `mediarvester/`) — wraps
every job:

```
with pipeline_run(job="finance.payslips.ingest",
                  inputs=[Dataset("nfs://homes/pittinic/bulletins-de-salaire")],
                  outputs=[Dataset("postgres://finance/bronze.payslip_file")],
                  contract="bronze.payslip_file") as run:
    ...   # job code; run.rows_read / run.rows_written / run.span
```

On enter/exit it does, uniformly:

| Concern | What the wrapper does |
|---|---|
| **OTel traces** | Root span per run (child spans per step); continues `TRACEPARENT` if the orchestrator passes one. OTLP → existing collector gateway → **Tempo**. |
| **OTel metrics** | `pipeline_run_duration_seconds`, `pipeline_rows_written`, `pipeline_contract_violations`, last-success timestamp → **Mimir**. Gives freshness alerts and a "pipeline health" Grafana board for free. |
| **OTel logs** | Structured logs carrying trace/run ids → **Loki**. |
| **OpenLineage** | `START` / `COMPLETE` / `FAIL` RunEvents with input/output datasets and facets (`schema`, `dataSource`, `outputStatistics`, `dataQualityAssertions`, column lineage where cheap). Transport: composite — HTTP to `OPENLINEAGE_URL` if set, **always** also append to `ops.openlineage_event` (jsonb). When a backend (Marquez / DataHub / OpenMetadata) shows up, replay the table. |
| **ODCS** | Before `COMPLETE`, run the output dataset's contract tests (schema drift + quality rules). A violation = `FAIL` event, non-zero exit, metric bump. |

Parent/child: an orchestrator-level run (Kestra execution, or the A-runner's
pipeline run) is passed as the OpenLineage **parent run facet**, so step runs
group under their pipeline in any future UI.

Open-source pieces: `opentelemetry-sdk` + OTLP exporter, `openlineage-python`,
`datacontract-cli` (reads ODCS, tests against Postgres, lints, exports DDL/dbt).
Verify current versions at implementation time.

### 1.2 Postgres layout

One **dedicated** Postgres, database `finance`. The stack already has Postgres
instances: per-consumer ones in `security` (LLDAP, Authelia) and the shared media
one, `transverse-db` (`src/media/templates/postgresql`, `postgres:17`, one DB per
*arr app, on the NFS-backed `apps` volume). Finance does not join any of them:
sensitive data, NFS is unsuitable for Postgres here, and the media instance shares a
superuser across apps.

| Schema | Content | Contract | Writers |
|---|---|---|---|
| `bronze` | As received, append-only, source lineage columns (`_source_path`, `_sha256`, `_ingested_at`, `_run_id`, `_parser_version`). No business cleaning. | Minimal ("as-received" shape + must-have lineage columns) | `ingest` role |
| `silver` | Typed, deduplicated, conformed entities (payslip, payslip_line, transaction, account, position, price). Idempotent upserts. | **Full ODCS** (types, keys, nullability, quality rules, classification) | `transform` role |
| `gold` | Business marts feeding Grafana: monthly income, YTD tax, net worth, savings rate, cashflow, forecasts. Views or tables. | **Full ODCS** + SLA (freshness) | `transform` role |
| `ops` | Run log, `openlineage_event`, review queue for low-confidence parses. Not a medallion layer, just plumbing. | — | wrapper library |

Roles: `grafana_ro` = SELECT on `gold` only (silver if needed); `ingest` and
`transform` as above. Data dir on a **local, node-pinned hostPath volume**
(`storage.localDb`), never NFS — per the repo's own findings
(`persistence/templates/local-db/`, LLDAP-over-NFS failure note in the Authelia
ConfigMap). Reuse its nightly backup CronJob.

Transformation: **dbt-core 1.12 + dbt-postgres**, run as a step of the wrapper
(`dbt-ol` for OpenLineage). Physical tables are created from the ODCS contracts
(`datacontract export sql --dialect postgres --server <srv>`, post-processed to
schema-qualify names); dbt never creates or drops them. Details, rules and
evidence in section 6.

### 1.3 Data contracts (ODCS)

- Format: **ODCS v3.x** YAML (Bitol). The ODCS docs currently show **v3.2.0**;
  confirm `datacontract-cli` supports the version you pin.
- Source of truth is the repo (`finance/contracts/<layer>.<dataset>.odcs.yaml`),
  one per silver/gold dataset (bronze: one thin contract per ingest source).
- **Contract = the only hand-maintained declarative artifact.** Generated from it,
  never edited (CI fails if the checked-in/generated output drifts):
  - physical DDL (`datacontract export sql --dialect postgres --server …`);
  - dbt model YAML (`datacontract export dbt-models --server …`; **always pass
    `--server`**, otherwise types come out Snowflake-style, e.g. `NUMBER(10,2)`,
    which Postgres rejects) and, for bronze, dbt sources (`dbt-sources`, not yet
    tried);
  - browsable docs (HTML export).
- Runtime gate: `datacontract test` against Postgres after each load (schema
  drift + quality rules; its Postgres example covers field presence, physical
  type, missing values, primary-key uniqueness, row counts and invalid-record
  counts; SQL-type quality rules are part of ODCS — confirm on our rules).
- CI: lint all contracts (`datacontract lint`) on every change.
- Fields to use deliberately: `classification` (PII!), `primaryKey`, `required`,
  `quality` (SQL rules), `slaProperties` (freshness), `servers`, `team`.
- ODCS has property-level `transformSourceObjects` / `transformLogic` /
  `transformDescription`. **Do not hand-maintain them**: they duplicate the SQL
  and will drift. Lineage is derived from the SQL (dbt-ol), never declared.
- Contract authoring gotchas found in the spike: the library quality metric is
  `rowCount` (not `rows`); contract-level `quality` of `type: sql` and per-property
  ones are both executed by `datacontract test`; the CLI needs
  `pip install "datacontract-cli[postgres]"` and the env vars
  `DATACONTRACT_POSTGRES_USERNAME` / `_PASSWORD`; the CLI's syntax is
  `datacontract export <format> <file>` (no `--format`).

Sketch (silver.payslip):

```yaml
apiVersion: v3.2.0          # pin; must match what datacontract-cli supports
kind: DataContract
id: urn:platypod:finance:silver:payslip
name: payslip
version: 1.0.0
status: active
domain: finance
dataProduct: payslips
servers:
  - server: finance-pg
    type: postgres
    database: finance
    schema: silver
schema:
  - name: payslip
    physicalType: table
    properties:
      - {name: period,        logicalType: date,   physicalType: date,          required: true, primaryKey: true}
      - {name: employer_siret, logicalType: string, physicalType: text,         required: true, classification: internal}
      - {name: gross_amount,  logicalType: number, physicalType: "numeric(10,2)", required: true, classification: confidential}
      - {name: net_before_tax, logicalType: number, physicalType: "numeric(10,2)", required: true, classification: confidential}
      - {name: withholding_tax, logicalType: number, physicalType: "numeric(10,2)", required: true}
      - {name: net_paid,      logicalType: number, physicalType: "numeric(10,2)", required: true}
    quality:
      - type: sql
        description: net paid reconciles with gross minus all deductions (±0.01)
        query: "SELECT count(*) FROM silver.payslip WHERE abs(net_paid - (gross_amount - total_deductions)) > 0.01"
        mustBe: 0
slaProperties:
  - {property: frequency, value: 1, unit: month}
```

### 1.4 Repo / deploy shape

- New dir `finance-pipelines/` (custom image → GHCR, like the others):
  - `platypod_pipeline/` — the wrapper library;
  - `contracts/*.odcs.yaml` — **the source of truth**;
  - `dbt/` — `dbt_project.yml`, `models/{silver,gold}/*.sql` (hand-written
    SELECTs, one per dataset), `models/**/*.yml` (**generated**, not edited);
  - `generated/ddl/*.sql` — generated from contracts, applied by the migration step;
  - `Makefile` — `generate` (contracts → DDL + dbt YAML), `check` (lint + drift),
    `test` (datacontract test).
- New stack module `stack/src/finance/`: Postgres, CronJobs (A) or Kestra (B),
  PVs/PVCs, secrets via platypod-sops, Grafana datasource + dashboards under the
  observability dashboards convention, `grafana_ro` provisioning.
- Grafana access: the finance dashboards in a folder restricted to your user
  (see `observability/dashboard-multitenancy.md`); the SQL datasource uses the
  read-only role.

### 1.5 First use case: payslips (inspected, structure only)

`~/nfs/.../bulletins-de-salaire/` holds **79 PDFs, 2020 → 2026, one employer**
(monthly, `YYYY/YYYYMM.pdf`). Findings that shape the design:

- ~~All born-digital, text-extractable → no OCR.~~ **Corrected in phase 1: 5 of the 79 files have no
  text layer** (print-to-PDF outlines) and are OCR'd; the rest use `pdfplumber`.
- **Two layouts** (the first two below turned out to be the same Silae generator), so parsers are **versioned** (`_parser_version` in bronze):
  1. 2020 → 2023: one page, a machine-readable header line
     (`<EMPLOYER>##BULLETIN##MM-YYYY##…`) — easiest to anchor on;
  2. 2024: one page, generated by Silae;
  3. 2025 → 2026: new layout, 2–3 pages, summary page ("salaire avant/après
     impôt", PAS, cumuls) + detailed lines page.
  Each parser outputs the same bronze shape; layout is detected, not configured.
- **Junk to skip**: macOS `._*.pdf` AppleDouble files and Synology `@eaDir`.
- **PII**: the PDFs carry the social-security number (NIR) and address. Bronze
  stores path + sha256 + parsed fields; **do not carry the NIR into silver** (drop
  or mark `classification: restricted` and exclude from gold/Grafana). The
  contract makes this explicit.
- **Free data-quality rules**: net paid = gross − contributions − withholding −
  other deductions; YTD cumuls (gross, taxable net, PAS) must equal the running
  sum of months. These become ODCS `quality` rules and catch mis-parses.
- **Storage**: the PDFs stay on the Synology (`homes/…`), read-only. It is **not**
  one of the existing `apps`/`media` PVCs, so a new read-only NFS PV/PVC is
  needed (and, per the repo rule, no `fsGroup` on it).
- Idempotency key = sha256 of the file; a re-issued payslip for the same period
  is a new bronze row, and silver keeps the latest by `_ingested_at`.

Dataset path: `bronze.payslip_file` → `bronze.payslip_line_raw` →
`silver.payslip`, `silver.payslip_line` → `gold.income_monthly`,
`gold.tax_withheld_ytd` (+ later `gold.savings_rate` once bank data lands).

---

## 2. Alternative A — light & native (no Kestra)

**Orchestration = Kubernetes CronJobs + a tiny in-image runner.**

- One image, several entrypoints. CronJobs per source: `payslips-ingest`
  (daily/weekly scan, no-op when nothing new), `stocks-ingest` (daily),
  `bank-ingest` (on demand / weekly), `transform` (dbt run + test).
- Dependencies: a `pipeline` entrypoint runs the steps of a DAG sequentially
  (ingest → silver → gold → contract tests) inside **one pod**, each step a child
  span + child OpenLineage job under one parent run. For 5–10 jobs that is all the
  orchestration needed; no cross-pod DAG engine.
- Retries: `backoffLimit` + idempotent jobs. Failures surface through the OTel
  metrics → Grafana alert (and `kubectl logs`/Loki). Manual backfill:
  `kubectl create job --from=cronjob/… -- --from 2024-01`.
- Event-driven wake-up ("a payslip landed") is a polling CronJob; KEDA is the
  upgrade path if ever wanted.
- Scheduling definitions are Helm values → same GitOps flow as the rest.

| | A |
|---|---|
| Always-on additions | Postgres only (~256–512 MB) |
| Per-run (ephemeral) | ~200–600 MB peak while a job runs (dbt + Python) |
| New services to operate | 1 (Postgres) |
| UI for runs/retries | none native → Grafana "pipeline health" board from OTel metrics |
| Cost of being wrong | low; trivially promoted to B |

**Strengths**: minimal footprint, nothing new to patch, consistent with the repo.
**Weaknesses**: no run UI, manual backfills, DAG logic is home-grown (in the
runner) — fine until the DAG grows.

---

## 3. Alternative B — robust (Kestra)

**Orchestration = Kestra, scheduling and running the same image's entrypoints.**

- Kestra (standalone, JVM) + its **own** Postgres backend (separate DB or
  instance from `finance`; ~+0.1–0.25 GB). Internal storage on a local PVC.
- Flows (YAML in git, deployed by sync flow/CI — verify the exact Kestra
  mechanism at implementation time) declare triggers (cron, file-arrival
  polling), dependencies, retries, and call the GHCR image via the **Kubernetes
  task runner** (a step = a short-lived pod) — so heavy work stays outside the
  Kestra JVM and resources are visible per step.
- Instrumentation is **unchanged** (library inside the image). Kestra adds: pass
  `execution.id`/flow as the OpenLineage parent run, and `TRACEPARENT` for trace
  continuity. Check what Kestra OSS exposes natively for OTel/OpenLineage; treat
  anything native as a bonus, never as a dependency.
- Gains: run UI, one-click rerun/backfill, retry policies, flow dependencies,
  alerting hooks, execution history — the things A lacks.
- Needs: Authelia forward-auth in front of the UI (OSS has basic auth only, as far
  as I know — verify), RBAC for the Kubernetes task runner (namespace-scoped
  pod create), a purge policy for execution history.

| | B |
|---|---|
| Always-on additions | Kestra JVM (~1–2 GB) + Postgres for Kestra + `finance` Postgres (~0.3 GB) |
| Per-run | step pods as in A, scheduled by Kestra |
| New services to operate | 3 (Kestra, its DB, finance DB) |
| UI for runs/retries | yes |
| Optional | scale Kestra to 0 outside windows (KEDA cron / scaling CronJobs) — only if its triggers all fall inside the windows |

**Strengths**: operability and visibility as the pipeline count grows; closer to
what "data engineering" tooling looks like. **Weaknesses**: ~1.5–2.5 GB more RAM
always on, more state to back up, an extra privileged component, JVM startup
latency; most of its value only appears with many interdependent flows.

---

## 4. Comparison and recommendation

| | A: CronJobs | B: Kestra |
|---|---|---|
| Idle RAM added | ~0.3–0.5 GB | ~1.5–2.5 GB |
| Run visibility | Grafana (OTel) | Kestra UI + Grafana |
| Backfill / rerun | CLI | UI |
| DAG complexity ceiling | ~10 jobs, linear | high |
| Instrumentation effort | same | same |
| Switching cost later | A→B: low | B→A: low |

**Recommendation: build A first.** Phase 1–3 are identical to both options; the
orchestrator is the last decision and the cheapest to reverse, because the
library, contracts, schemas, image and dashboards are orchestrator-agnostic.
Move to B when you feel the missing rerun UI or have a dozen+ interdependent
flows. (To get the Kestra UI earlier at low cost: run it in a scale-to-zero
window and keep CronJobs as production schedule — I would not.)

## 5. Phases

0. **Foundation** — `finance` Postgres + `localDb` volume + roles; Grafana
   datasource; `finance-pipelines` skeleton + image; `platypod_pipeline` with OTel
   + OpenLineage-to-`ops` + contract runner; `make generate`/`check` (contract →
   DDL + dbt YAML + drift check); a trivial heartbeat pipeline (ingest → dbt
   model → contract test) proving traces/metrics/logs/lineage rows end to end,
   including `dbt-ol` events nested under the wrapper's run.
1. **Payslips** — NFS PV, 3 parsers, bronze/silver/gold, contracts + quality
   rules, `income_monthly` + tax dashboards. (79 files = a real backfill test.)
2. **Bank statements** — CSV/OFX ingest, categorisation (rules table), cashflow
   and savings rate (joins payslips).
3. **Stocks/portfolio** — daily prices, positions, valuation, net worth.
4. **Forecasts** — SQL/Python in transform → `gold.forecast_*`.
5. **Decide A vs B for real**, and optionally stand up an OpenLineage backend
   (Marquez is the lightest: API + UI + Postgres; OpenMetadata/DataHub are
   heavier — OpenMetadata needs a search engine) and replay `ops.openlineage_event`.

## 6. dbt × ODCS integration (validated by spike)

Decision: **dbt now**, with the contract owning the DDL. This section records how
the two fit together and the evidence. Spike run on 2026-10-02 against a throwaway
Postgres 17, with `datacontract-cli` 1.2.2, `dbt-core` 1.12.5, `dbt-postgres`
1.11.0, `openlineage-dbt` / `openlineage-sql` 1.53.0, on a synthetic
`silver.payslip` contract (one SQL quality rule per property and per table, a
`rowCount` rule, a primary key, `classification`).

### 6.1 Division of labour

| Concern | Owner | Mechanism |
|---|---|---|
| Schema, types, keys, nullability, classification, SLA, ownership | **ODCS** | hand-written contract |
| Physical tables (incl. real `PRIMARY KEY`) | **ODCS** | generated DDL |
| Quality rules / the gate | **ODCS** | `datacontract test` after each load |
| What each dataset *is made of* (the SELECT) | **dbt model** | hand-written SQL, one file per dataset |
| Run order, incremental logic, selective rebuild | **dbt** | `ref()`/`source()`, `incremental`, `--select` |
| Lineage (table + column) | **dbt** (`dbt-ol`) | derived from the SQL, not declared |
| dbt model YAML (types, constraints, descriptions, `classification` as `meta`) | generated from ODCS | `export dbt-models --server …`, never edited |

Hand-written, therefore: contracts + model SQL (+ trivial dbt boilerplate:
`dbt_project.yml`, `profiles.yml`, sources). Everything else is generated.

### 6.2 Operating mode: "dbt fills, the contract creates"

1. `make generate`: contracts → `generated/ddl/*.sql` + `dbt/models/**/*.yml`.
2. Migration step applies the DDL (tables exist, with real PKs).
3. Every silver/gold model is `materialized='incremental'`
   (`unique_key=<pk>`, `on_schema_change='fail'`, `full_refresh=false`) or `view`
   for gold. Put this in a `config()` header in the model's `.sql`, **not** in the
   generated YAML.
4. Wrapper runs `dbt-ol build` (with `OPENLINEAGE_PARENT_ID` = the wrapper's run),
   then `datacontract test`; a violation fails the pipeline.

Why not "dbt creates the tables" (the exported default, `materialized: table`):
it works, but dbt rebuilds the table every run and the contract's primary key
becomes a unique constraint named `payslip__dbt_tmp_period_key`, so the contract
no longer owns the physical shape. The contract-owned mode avoids both.

### 6.3 Spike results

| Question | Result |
|---|---|
| Does the CLI accept an ODCS 3.2.0 contract? | **Yes** — validated against v3.2.0. |
| `export sql --dialect postgres` fidelity | Good: `date`, `text`, `numeric(10,2)`, `NOT NULL`, `PRIMARY KEY`. **Not** schema-qualified (`CREATE TABLE payslip`) and no `COMMENT`s: post-process (sed/`search_path`) or add a small generator for comments/classification. |
| `export dbt-models` fidelity | Good **only with `--server`** (without it: `data_type: NUMBER(10,2)` → `type "number" does not exist` on Postgres). Carries names, types, descriptions, `not_null`/`unique`, `classification` → `meta`, `contract.enforced: true`. Hard-codes `materialized: table`. **ODCS SQL quality rules are not exported to dbt tests** (good: no second, drifting copy). PK is exported as `not_null` + `unique`, not `primary_key`. |
| Can the model's `config()` override the generated YAML? | **Yes** — `incremental` in the `.sql` beat the YAML's `table`. |
| Contract-owned DDL + incremental model | **Works.** Idempotent re-runs; the real `payslip_pkey` PRIMARY KEY survives; `--full-refresh` does **not** drop the table when `full_refresh=false`. |
| `datacontract test` against Postgres | **Works**, on dbt-built *and* contract-built tables. The deliberately inconsistent rows were caught by the SQL reconciliation rule (`Actual custom_sql(payslip) was 2, expected = 0`). The per-column SQL rule and the `rowCount` rule also executed. |
| dbt + Postgres on current dbt | **dbt-core 1.12.5 + dbt-postgres 1.11.0 run fine.** (dbt Core v2 / Rust: not tested; Postgres support there is unconfirmed — pin 1.12.x.) |
| `dbt-ol` (OpenLineage) on dbt 1.12.5 + Postgres | **Works.** With `OPENLINEAGE_PARENT_ID` it emitted START/COMPLETE for the dbt run (child of my parent job) and for the model, with input `bronze.payslip_raw`, output `silver.payslip`, and a **`columnLineage` facet**. Events are emitted in a batch *after* the run. |
| `openlineage-sql` on Postgres SQL | Parsed a 3-column sample (a `to_date(...)` expression, a plain alias, a `replace(...)::numeric` cast) and returned correct column lineage for all three. So the plain-SQL fallback for lineage is viable on simple models; its handling of joins/CTEs/window functions is untested. dbt-ol additionally yields the whole event structure (jobs, parent facets, dataset facets). |

### 6.4 Consequences for the design

- Wrapper ↔ dbt-ol: the wrapper emits the **pipeline-level** run and passes its
  run id as `OPENLINEAGE_PARENT_ID`; dbt-ol emits the **model-level** jobs. The
  wrapper must not also describe the dbt datasets (no double events). dbt-ol is
  configured with a file transport and the wrapper loads that JSONL into
  `ops.openlineage_event` after the step (or a custom transport — to design in
  phase 0).
- OpenTelemetry has no dbt hook: wrap the dbt step in a span; per-model spans
  could be derived from `run_results.json` after the run.
- Gold as `view` + `contract: enforced` was **not tested**; verify in phase 0.
  Fallback: gold as incremental tables, or contract enforcement only on silver.
- `datacontract export dbt-sources` for bronze, multi-contract exports and
  cross-dataset relationships were **not tested**.
- The generation + drift check is a CI invariant: regenerate, `git diff
  --exit-code`.

### 6.5 What this costs, honestly

- A dbt dependency in the image (Python + dbt-core + adapter) and a second
  language layer (Jinja + YAML) for what is, in phase 1, two silver tables and
  two or three gold views. Plain SQL would be smaller *today*.
- The contract is the only declarative source, but it is **not** the only
  hand-written artifact: model SQL and a few dbt files remain.
- Dependency on `datacontract-cli`'s exporters (young, fast-moving: its CLI
  syntax changed between versions). Mitigation: pin versions; the DDL generator
  can be replaced by ~50 lines of own code, and dbt YAML by hand-writing without
  losing the contract.
- Why it is still worth it: lineage (table + column) and OpenLineage events come
  for free, incremental/selective-rebuild machinery exists before the bank and
  stock phases need it, and the integration risks I had flagged were checked and
  resolved rather than left for later.

### 6.6 Escape hatch

Because the model files are pure `SELECT`s and the contract owns the DDL, dropping
dbt later means wrapping each file in an `INSERT … ON CONFLICT` / view in the
wrapper and declaring step inputs/outputs by name; contracts, schemas, dashboards
and the image stay. The reverse (plain SQL → dbt) is as cheap, so the choice is
reversible either way.

## Deferred / risks

- **Backup encryption — deferred by choice.** The local-db backup CronJob writes
  plain dumps to the Synology, where prod NFS has *no snapshots* (see
  `persistence/README.md`). Finance data would sit unencrypted there. Revisit
  before bank data lands (phase 2); an `age`-encrypted dump + off-box copy is
  the minimal fix.
- Single-node hostPath for the DB: node loss = restore from backup.
- Payslip parser drift when the employer's template changes: the contract tests
  and the `ops` review queue are the safety net.
- Contract/tool versions (ODCS 3.x minor, `datacontract-cli`, Kestra
  OTel/OpenLineage support) must be verified when implementation starts.
