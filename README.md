# pv-r-engine

Open-source R engine that computes the **PV Nature Pillar Metrics** for
CitizenClimate, an applicant Plan Vivo **Data Analytic Provider (DAP)**.

Per the [DAP Requirements](https://www.planvivo.org) §2.1, the Pillar Metrics
are computed with the canonical R packages — **no reimplementation** — and the
analytical process is fully transparent and reproducible. This repo is the
auditable artefact: a VVB clones it at the commit SHA recorded in
`metricsRuns/{runId}`, runs `renv::restore()`, and reproduces every number.

## What it computes

| Pillar | Metric | Function (package) | Status |
|--------|--------|--------------------|--------|
| 1 | Species Richness — Hill q=0 | `iNEXT::iNEXT(q=0)` | ✅ `R/pillar1.R` |
| 2 | Species Diversity — Hill q=1, per group then summed | `iNEXT::iNEXT(q=1)` | ✅ `R/pillar2.R` |
| 3 | Taxonomic Dissimilarity — Δ\*/Δ+ | `vegan::taxa2dist` + `vegan::taxondive` | ✅ `R/pillar3.R` |
| 4 | Habitat Health — NDVI median → SBI | `geodiv::sbi` | 🚧 Phase 3 |
| 5 | Habitat Spatial Structure — CPLAND | `landscapemetrics::lsm_c_cpland` | 🚧 Phase 3 (every 5y) |

GBIF Backbone Taxonomy is the single source of truth for species classification
(resolved upstream in the CitizenClimate Cloud Functions, passed in as
`taxonomyTree`). Only **within-system** change is measured — no reference sites
or counterfactuals (DAP §2.1).

## Architecture

Runs on the existing Hetzner box alongside BirdNET-Analyzer, as a `plumber` HTTP
service behind nginx + Let's Encrypt, authenticated with the same `X-API-Key`
header pattern. CitizenClimate's `runPillarMetrics` Cloud Function builds the
species×count matrix and `POST`s it to `/run`; this engine returns pillar values
+ provenance. See `../functions/index.js` (`runPillarMetrics`).

```
Cloud Function runPillarMetrics ──HTTPS+X-API-Key──▶ plumber /run ──▶ iNEXT / vegan
        │                                                                   │
        └────────────── writes pillarMetrics + metricsRuns ◀── JSON result ─┘
```

## API

- `GET /health` → `{ status, rVersion, packageVersions }`
- `POST /run` (X-API-Key) — body is the contract in `runPillarMetrics`:
  `{ runId, projectId, year, pillars, speciesCountMatrix, taxonomyTree, ... }`,
  returns `{ runId, pillars: { "1": {...}, "2": {...}, "3": {...} }, rVersion, packageVersions, hostFingerprint, computedAt }`.

`speciesCountMatrix` is `{ "<targetGroup>": { "<scientificName>": count } }`;
Pillars 1 & 2 are computed per Target Group then summed (Methodology §1.5.1/§1.5.2).

## Determinism

`set.seed(42)` is set at startup, so all iNEXT bootstrap draws are reproducible.
The orchestrating Cloud Function hashes the input (`inputSnapshotSha256`); re-runs
on identical input are short-circuited to the cached result.

## Deploy (Hetzner)

```bash
sudo bash scripts/install.sh                       # GDAL + R + renv::restore + systemd + nginx
sudo certbot --nginx -d citizenclimate-pv-r.duckdns.org
curl -H "X-API-Key: $(cat /etc/cc-pv-r/api-key)" https://citizenclimate-pv-r.duckdns.org/health
```

Then set the Cloud Function secrets:

```bash
firebase functions:secrets:set PV_R_API_URL   # https://citizenclimate-pv-r.duckdns.org
firebase functions:secrets:set PV_R_API_KEY   # same value as /etc/cc-pv-r/api-key
```

Set `PV_R_API_KEY` to *exactly* the box's key (a mismatch makes the R engine
return 401). The safest way:

```bash
ssh root@<box-ip> 'cat /etc/cc-pv-r/api-key' | firebase functions:secrets:set PV_R_API_KEY --data-file -
```

### Audit-bundle Storage access (one-time IAM)

`runPillarMetrics` uploads the reproducibility `.zip` to
`gs://<project>.firebasestorage.app/pv-audit-bundles/{runId}.zip`, and
`getAuditBundleUrl` returns a 24h **signed** URL. Signed URLs grant access *as
the signing service account* (the `GOOGLE_SERVICE_ACCOUNT` secret), so that SA
needs Storage read:

```bash
gcloud projects add-iam-policy-binding <project> \
  --member="serviceAccount:<sa-email>" \
  --role="roles/storage.objectViewer" --condition=None
```

## Reproduce a single pillar (what a VVB does)

```bash
Rscript -e "renv::restore(prompt = FALSE)"
Rscript R/pillar1.R inputs/species_count_matrix.csv   # CSV: targetGroup,scientificName,count
```

## Status / caveats

- Pillars 1–3 are implemented; **Pillars 4 & 5** (Sentinel-2 NDVI → `geodiv::sbi`,
  habitat raster → `landscapemetrics::lsm_c_cpland`) land in Phase 3.
- The R was authored against the methodology and the named functions but must be
  run on the box against a real test dataset before the DAP **sample report**
  (DAP §3) is submitted to Plan Vivo.
- `renv.lock` currently pins only the **Phase-1** packages (`iNEXT`, `vegan`,
  `plumber`, `jsonlite`, `httr`). The heavier spatial stack (`terra`, `geodiv`,
  `landscapemetrics`) is added back in Phase 3 when Pillars 4–5 land — keeping it
  out lets the engine install on a small 1-core box without long source builds.
- `scripts/restore.R` installs from Posit P3M Linux binaries where available;
  regenerate the lock with `renv::snapshot()` to capture exact hashes.
