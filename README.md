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
| 4 | Habitat Health — P4 = z05 / σ(NDVI) = 1 / SBI of the median NDVI raster | `geodiv::sbi` | ✅ `R/pillar4.R` |
| 5 | Habitat Spatial Structure — CPLAND of low-intensity-use habitat | `landscapemetrics::lsm_c_cpland` | ✅ `R/pillar5.R` (baseline + every 5y) |

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

## Satellite pillars (4–5)

A second plumber service, `sat_api.R`, runs beside `api.R` (systemd
`pv-sat-engine`, `127.0.0.1:8002`, exposed by nginx under `/sat/` with the same
`X-API-Key`), so a multi-minute Sentinel-2 run never blocks a species run.
CitizenClimate's `runSatellitePillars` Cloud Function sends the project's site
boundary (WGS84 GeoJSON) and its sampling-plan parameters.

| Step | What happens | Where |
|------|--------------|-------|
| Grid | Boundary → 10 m grid in the UTM zone of the site centroid, snapped to the Sentinel-2 pixel grid | `R/sat_common.R` |
| Imagery | Sentinel-2 L2A Collection 1 COGs (AWS Open Data, via Element 84 Earth Search STAC); only the site window is read | `R/pillar4.R` |
| Cloud mask | L2A cloud probability (`CLD_20m`) above the project threshold (default 40 %), plus SCL classes 0, 1, 3, 8, 9, 10 | `R/pillar4.R` |
| NDVI | Per-pixel median over the project's fixed three-month window | `R/pillar4.R` |
| Pillar 4 | `1 / geodiv::sbi(ndvi)`: geodiv defines SBI = Sq / z05, and Methodology Eq. 6 is P4 = z05 / σ | `R/pillar4.R` |
| Season | If the project has no window yet, the 12-month NDVI profile picks the 3 greenest months; the Cloud Function pins it so every later year uses the same window | `p4_auto_season()` |
| Habitat map | Impact Observatory / Esri 10 m annual land use / land cover v02 (Sentinel-2-derived, CC BY 4.0, Microsoft Planetary Computer), latest year ≤ monitoring year | `R/pillar5.R` |
| Pillar 5 | Land cover → low-intensity (project's class list) vs intensive use → `lsm_c_cpland(directions = 8, consider_boundary = FALSE, edge_depth = 1)` (10 m edge) | `R/pillar5.R` |

- `GET /sat/health` → `{ status, packageVersions (terra, geodiv, landscapemetrics, GDAL), sources }`
- `POST /sat/run` → `{ runId, year, pillars: [4, 5], boundaryGeoJSON, ndviSeasonStartMonth | null, cloudProbThreshold, habitatLowUseClasses, hashedInputJson, inputSnapshotSha256 }`
  returns `{ pillars: { "4": {...}, "5": {...} }, errors, auditBundleZipBase64, ... }`. A user-facing
  problem (season not finished, no clear pixels, site too large) is a `422` with a message.

Each satellite run ships its own audit bundle: the exact hashed input
(`sha256sum inputs/hashed_input.json` equals the recorded hash), the boundary, the
Sentinel-2 scene list and land cover tiles used, the NDVI median / valid-count /
land cover / habitat rasters, and the code. A VVB checks it with:

```bash
Rscript R/sat_reproduce.R verify <bundle_dir>   # recompute P4 and P5 from the shipped rasters
Rscript R/sat_reproduce.R rerun  <bundle_dir>   # re-download the recorded scenes and repeat everything
```

Open points to confirm with Plan Vivo (recorded on every run so the TRP can review them):

- The Methodology names the GEE "Sentinel-2: Cloud Probability" (s2cloudless) dataset. Outside GEE the
  engine uses the L2A product's own cloud probability layer (Sen2Cor `MSK_CLDPRB`) plus the SCL mask.
- The annual land cover product lags (latest year 2023 at the time of writing); runs flag
  `landcover_older_than_monitoring_year`. Methodology §2.5 prefers a project-supplied habitat map.
- `consider_boundary = FALSE` treats cells on the site boundary as edge; Eq. 7's wording could be read
  either way.
- The post-hoc significance screening of pillar changes (Methodology §1.9) is not applied to the Multimetric yet.

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

Adding the satellite service to the existing box:

```bash
sudo git -C /srv/cc-pv-r pull --ff-only               # the upgrade script ships in this pull
sudo bash /srv/cc-pv-r/scripts/upgrade_satellite.sh   # spatial R stack, pv-sat-engine unit, nginx /sat/
curl -H "X-API-Key: $(sudo cat /etc/cc-pv-r/api-key)" https://citizenclimate-pv-r.duckdns.org/sat/health
```

SSH is allowed only from the allow-listed IP in the Hetzner Cloud firewall; from
elsewhere use the server's **Console** tab in console.hetzner.cloud.

Fresh box:

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

- Pillars 1–5 are implemented. Pillars 4–5 are terrestrial only; marine projects follow the
  seagrass Approved Approach (field data).
- The R was authored against the methodology and the named functions but must be
  run on the box against a real test dataset before the DAP **sample report**
  (DAP §3) is submitted to Plan Vivo.
- `renv.lock` pins the top-level packages (`iNEXT`, `vegan`, `plumber`, `jsonlite`,
  `httr`, and for Pillars 4–5 `terra`, `geodiv`, `landscapemetrics`, `sf`). Their
  dependencies are resolved at restore time; run `renv::snapshot()` on the box to pin all of them.
- `scripts/restore.R` installs from Posit P3M Linux binaries where available;
  regenerate the lock with `renv::snapshot()` to capture exact hashes.
