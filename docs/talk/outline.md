# Talk outline — "Four and a half months of a homelab that grew up"

Target: ~45 min of talk + Q&A on top. Draft 2026-11-04.
Spine: one stack, three stories (a design, a postmortem, a teaser), bracketed by an honest overview and backlog.

| # | Segment | Min | Role |
|---|---------|-----|------|
| 0 | Hook | 2 | Why a homelab is a good engineering lab |
| 1 | Global overview | 8 | What exists, how it got built, the timeline |
| 2 | Multi-user Grafana on OSS | 16 | Main design talk |
| 3 | The NFS fsync postmortem | 9 | Story with a plot twist |
| 4 | Finance platform teaser | 5 | ODCS > dbt > Postgres > Grafana, OTel + OpenLineage |
| 5 | Backlog and close | 5 | Honest state of things |
| | **Total** | **45** | Cut 4 min from segment 2 for a 40-min slot |

The callbacks are what make it one talk: segment 4 reuses segment 2's shim for its dashboards, and
segment 2's "use each backend's native primitive" reappears in segment 3's "Postgres belongs on local disk".

---

## 0. Hook (2 min)

- One sentence: Kubernetes on Apple Silicon Macs plus one bare-metal box, running ~60 services for a household.
- Promise: three things that were non-obvious, one that is still unfinished.
- Rule of the talk: every segment ends with a rejected alternative, because that is the part that is never in the README.

## 1. Global overview (8 min)

Slides:
1. **The hardware**: `chuwi-cp1` (bare-metal control plane, amd64, 8C/16T, 64 GB, also schedulable), `mini4-w1` + `mini1-w2` (Mac minis, arm64, Talos VMs under vfkit), Synology NFS for bulk data. Source: README.md, infra/docs/baremetal-cp-migration.md.
2. **The layers**: Talos + Terraform/OpenTofu (`infra/`) then Helm charts reconciled by Flux (`stack/`), secrets in a separate SOPS repo. Local (laptop cluster) vs prod table.
3. **The module map**: core, security, dev-tools, media, files, games, observability, persistence, finance. One or two example services each (stack/docs/services.md). Custom images: mediarvester, pokeclicker, cyber-chef, transmission-exporter, finance-pipelines.
4. **One rule worth showing**: `dev` deploys local, `main` deploys prod, merging `dev` into `main` IS the prod deploy; image automation writes only to `dev` (stack/docs/branching.md).
5. **Timeline** (from git history and the docs):
   - 2026-06-19 first commit
   - 2026-06 to 07 libvirt/QEMU abandoned, vfkit + socket_vmnet, bridged vmnet rejected
   - 2026-07-30 control plane moves to bare metal
   - 2026-08-14 NFS/Postgres incident (segment 3)
   - 2026-09-01 branch-based promotion replaces tag gate
   - 2026-10-03 finance live on prod (segment 4)
   - 144 commits in about 4.5 months; the July peak is 80 commits.
6. **One slide of "what I deliberately did not build"**: MetalLB in prod, bridged networking, Keycloak.

Do not go deep here; the goal is context for segments 2 to 4 and a map the audience can return to in Q&A.

## 2. Multi-user Grafana on OSS (16 min)

Source of truth: stack/docs/observability/dashboard-multitenancy.md, stack/docs/decisions.md.

| Min | Beat | Content |
|-----|------|---------|
| 2 | The ask | Shared dashboards. A user sees only their own data, admins see everyone's. Grafana OSS has no datasource permissions and no LBAC (Enterprise only), so isolation has to be enforced below Grafana. |
| 3 | The insight | **Data shape decides the mechanism.** Per-authenticated stream (Claude transcripts, one identity per shipper) goes to a Loki *tenant*, a storage-layer wall. Co-mingled at one source (Jellyfin: one scrape, all users in a label) goes to *label* isolation. Tenancy isolates at the write boundary, so it cannot split one scrape. |
| 4 | The architecture | Diagram: Grafana, then the **scope shim** (reads `X-Grafana-User`, looks up LLDAP groups with a cache, injects scope), then `prom-label-proxy` (injects `owner=~...`), then Mimir. Logs: a second shim instance sets `X-Scope-OrgID`, admins get a federated tenant list built by enumerating LLDAP. Admin-ness is live group membership, no hardcoded list. Detail worth a slide: `owner` is stamped on *every* series (`_shared` for infra) because prom-label-proxy rejects regexes that match the empty string. |
| 3 | The graveyard | Viewer lockdown (soft boundary). Full multitenancy (fights admin-sees-all, cannot do Jellyfin). Two datasources with an admin bypass (OSS cannot restrict a datasource). `oauthPassThru` plus Authelia 4.39 bearer-authz (wrong audience, scope and flow). Replacing Authelia (the shim is inherent glue under any IdP). |
| 2 | Trust boundary | Flannel does not enforce NetworkPolicy, so `X-Grafana-User` could be forged by any pod. Real control: shared-secret header, and the shim overwrites any client-supplied `X-Owner` / `X-Scope-OrgID`. NetworkPolicy shipped as defense in depth. |
| 2 | Ingest hardening | `--owner` is client-declared. Fix: a `tenant-guard` ForwardAuth that 403s when `x-scope-orgid` is not `claude-<Remote-User>`. Guard chosen over `headers_setter` stamping because the stamp cannot template a prefix, so it would force a rename plus re-ship. Honest gap: the Mimir `owner` label lives in the payload and can still be forged. Left open on purpose. |
| 2 | Decisions have half-lives | Mimir multitenancy was rejected, then came back on a *different axis* (by theme, `ai`/`finance`/`anonymous`) because Mimir has no delete-series API (grafana/mimir#4968) and a bad batch of labels could not be wiped. New sentinel `_admin` for admin-only dashboards with zero shim changes. |

Demo ideas (pick one):
- Same PromQL query through the shim with two users' headers: different series sets, admin sees all. Record it, do not do it live.
- Show the 403 from `tenant-guard` when a writer forges another tenant.

Closing line: *Pick the backend's native primitive, enforce below the UI, and write down what you rejected.*

Honest-story option (30 seconds, good for credibility): the "user A sees user B's data" report that was never reproduced. Verification through the real shim chain was correctly scoped every time; the suspected cause is an Authelia SSO session bleed on a shared device with `auto_login: true`.

## 3. The Postgres-on-NFS postmortem (9 min)

Source: infra/docs/decisions.md ("Postgres/MySQL data dirs off NFS", 2026-08-14); related earlier SQLite-on-NFS fix.

Timeline slides:
1. **Symptom**: logins intermittently failed with `ldap: connection timed out`, cascading into broken OIDC token/consent exchanges across apps.
2. **Why it hid for two weeks**: sessions last up to 30 days, single binds were always fast. Only concurrency exposed it.
3. **Reproduction**: 25 parallel LDAP binds against a healthy LLDAP, all failed, none completed. Sequential: fast.
4. **Root cause**: LLDAP's Postgres data dir on the NFS share. Checkpoints took 34 s and 42 s, mostly `sync`. Same family as SQLite WAL on NFS.
5. **The detour (the best slide)**: tuned Authelia's LDAP timeout and enabled connection pooling (`count: 10`). It backfired: 10 persistent, continuously health-checked connections turned an occasional burst failure into constant background load. Reverted.
6. **The fix**: `storage.localDb`, a node-local hostPath volume plus a nightly backup to NFS, extending the existing `localConfig` pattern. Migrated authelia-db, lldap-db, outline-db, media-db, rommapp-db.
7. **The second bug the fix created**: the node marker label was unique to one node, so it was safe. Adding a second node meant a pod could reschedule onto the other node and silently start from an *empty* hostPath. Fix: every volume also pins `kubernetes.io/hostname`.
8. **Migration mechanics**: scale to 0, one-off pod mounting old NFS subpath read-only plus the new PVC, `cp -a`, redeploy. Old NFS copies kept as the rollback.

Lessons (one slide):
- Test concurrency, not a single request.
- Tuning can mask a problem or make it worse; measure before and after.
- A fix can remove the safety property an old design had by accident.
- Closing hook: the same mistake nearly repeated with finance, whose plan names `localDb` from day one.

## 4. Finance platform teaser (5 min)

Source: docs/plans/finance-data-platform.md, stack/src/finance/README.md, finance-pipelines/.

Keep it to one diagram and three hooks:
- **Diagram**: payslip PDFs, then bronze (as received), silver (typed, full ODCS contract), gold (marts), then Mimir tenant `finance`, then the *same shim* from segment 2, then Grafana.
- **Hook 1, contracts own the DDL**: ODCS YAML is the single source of truth for schema, quality rules, SLAs and PII classification. DDL and dbt YAML are generated. dbt only fills tables; it never creates them. The only hand-written artifact is the `SELECT`.
- **Hook 2, instrumentation lives in the job**: a small wrapper emits OTel traces/metrics/logs and OpenLineage events regardless of orchestrator, and always appends events to a table so a lineage backend can be added later and replayed.
- **Hook 3, the numbers**: 79 payslips, 2020 to 2026, no gaps; 5 had no text layer and needed OCR; year-to-date gross recomputed from months matched the printed value on 74 of 74 that print it.
- **Cliffhanger**: "A full talk on its own: what happens when the contract fails a run."

Use synthetic or heavily redacted figures on every slide. This is salary data.

## 5. Backlog and close (5 min)

Three-column slide: **Done / In flight / Backlog**, drawn from stack/docs/TODO.md and infra/TODO.md.

- Done: bare-metal control plane, Flux GitOps, SOPS, OIDC across ~8 apps, per-user observability, local DB volumes, finance phase 0 and 1.
- In flight: Flux `source-controller` crash-loop on prod (2917 restarts in 67 days, planned fix is to pin to the less loaded node and loosen the liveness probe); finance backup encryption; a documented Grafana login test on prod.
- Backlog: Talos/Kubernetes in-place upgrades (today a `talos_version` bump recreates VMs and loses etcd); etcd backup daemon not Terraform-managed; alerting (Alertmanager and rules); public stack never verified from mobile data; consolidated ADR index; Authelia JWKS key rotating on every render.

Closing line options:
- "Half of what I learned is in the rejected-alternatives sections."
- Or end on the 2917 restarts: "It still works. That is the problem."

---

## Check before presenting

- `dashboard-multitenancy.md` status line fixed 2026-11-04: the shim, label proxy and tenant-guard are running on prod.
- The Grafana UI login path through the live scope shim is still **not verified** on prod. Say so, or verify first.
- Flux on prod: as of 2026-11-04 four controllers were in `CrashLoopBackOff` and the planned fix was not applied (see infra/TODO.md). Check it before the talk; it is also your best closing anecdote if it is still happening.
- `multi-host.md` and the "LAN exposure" section of `infra/TODO.md` were corrected 2026-11-04.
- Anonymise real usernames and any salary figures on slides; blur hostnames if the deck will be shared.
- Re-derive the commit counts right before the talk; they were taken on 2026-11-04.
- Record demos, do not run them live on prod.
