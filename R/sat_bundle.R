# Audit-bundle builder for satellite runs (Pillars 4–5). Same idea as
# bundle.R: everything a VVB needs to re-derive the numbers, zipped and
# returned base64 for the Cloud Function to upload to Firebase Storage.
#
#   audit_bundle_{runId}.zip
#   ├── README.md
#   ├── inputs/     hashed_input.json (the exact bytes behind inputSnapshotSha256),
#   │               site_boundary.geojson, s2_scenes.csv, landcover_items.csv
#   ├── code/       sat_api.R, R/*.R, renv.lock
#   ├── outputs/    satellite_pillars.json, ndvi_median.tif, ndvi_valid_count.tif,
#   │               landcover_10m.tif, habitat_10m.tif
#   └── provenance/ run_metadata.json, host_fingerprint.txt,
#                   renv_lock_sha256.txt, code_commit_sha.txt

build_sat_audit_bundle <- function(run_id, site, request, p4, p5, pillars_out, meta) {
  code_dir <- Sys.getenv("PV_CODE_DIR", "/srv/cc-pv-r")
  runs_dir <- Sys.getenv("PV_RUNS_DIR", "/var/lib/cc-pv-r/runs")
  base <- file.path(runs_dir, paste0("sat_", run_id))
  unlink(base, recursive = TRUE)
  for (d in c("inputs", "code", "outputs", "provenance")) {
    dir.create(file.path(base, d), recursive = TRUE, showWarnings = FALSE)
  }

  # ── inputs ────────────────────────────────────────────────────────────────
  # Written verbatim so `sha256sum inputs/hashed_input.json` equals the
  # inputSnapshotSha256 recorded on the run.
  if (!is.null(request$hashedInputJson)) {
    con <- file(file.path(base, "inputs", "hashed_input.json"), "wb")
    writeBin(charToRaw(enc2utf8(request$hashedInputJson)), con)
    close(con)
  }
  writeLines(site$geojson, file.path(base, "inputs", "site_boundary.geojson"))
  writeLines(jsonlite::toJSON(request[setdiff(names(request), c("hashedInputJson", "boundaryGeoJSON"))],
                              auto_unbox = TRUE, pretty = TRUE, null = "null"),
             file.path(base, "inputs", "request.json"))
  if (!is.null(p4)) utils::write.csv(p4$scenes, file.path(base, "inputs", "s2_scenes.csv"), row.names = FALSE)
  if (!is.null(p5)) utils::write.csv(p5$landcoverItems, file.path(base, "inputs", "landcover_items.csv"), row.names = FALSE)

  # ── code ──────────────────────────────────────────────────────────────────
  for (f in c("sat_api.R", "renv.lock")) {
    src <- file.path(code_dir, f)
    if (file.exists(src)) file.copy(src, file.path(base, "code", f), overwrite = TRUE)
  }
  dir.create(file.path(base, "code", "R"), showWarnings = FALSE)
  for (f in list.files(file.path(code_dir, "R"), full.names = TRUE)) {
    file.copy(f, file.path(base, "code", "R", basename(f)), overwrite = TRUE)
  }

  # ── outputs ───────────────────────────────────────────────────────────────
  writeLines(jsonlite::toJSON(pillars_out, auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA),
             file.path(base, "outputs", "satellite_pillars.json"))
  for (f in c(if (!is.null(p4)) unlist(p4$files), if (!is.null(p5)) unlist(p5$files))) {
    if (file.exists(f)) file.copy(f, file.path(base, "outputs", basename(f)), overwrite = TRUE)
  }

  # ── provenance ────────────────────────────────────────────────────────────
  renv_sha <- .sys("sha256sum", file.path(code_dir, "renv.lock"))
  if (!is.na(renv_sha)) renv_sha <- sub("\\s.*$", "", renv_sha)
  commit <- .sys("git", c("-C", code_dir, "rev-parse", "HEAD"))
  host <- Sys.getenv("PV_HOST_FINGERPRINT", unset = Sys.info()[["nodename"]])
  writeLines(as.character(host %||% ""), file.path(base, "provenance", "host_fingerprint.txt"))
  writeLines(as.character(renv_sha %||% ""), file.path(base, "provenance", "renv_lock_sha256.txt"))
  writeLines(as.character(commit %||% ""), file.path(base, "provenance", "code_commit_sha.txt"))
  writeLines(jsonlite::toJSON(list(
    runId = run_id, kind = "satellite", rVersion = R.version.string,
    packageVersions = pv_sat_versions(), hostFingerprint = host,
    codeCommitSha = commit, renvLockSha256 = renv_sha,
    inputSnapshotSha256 = request$inputSnapshotSha256 %||% NA,
    computedAt = meta$computedAt %||% NA, year = request$year %||% NA
  ), auto_unbox = TRUE, pretty = TRUE, na = "null"), file.path(base, "provenance", "run_metadata.json"))

  # ── README ────────────────────────────────────────────────────────────────
  writeLines(c(
    "# PV Nature Satellite Pillars (4–5) — Audit Bundle",
    "",
    sprintf("Run: %s", run_id),
    sprintf("Monitoring year: %s", request$year %||% ""),
    sprintf("Computed: %s", meta$computedAt %||% ""),
    sprintf("R: %s", R.version.string),
    "",
    "## Check the input hash",
    "```",
    "sha256sum inputs/hashed_input.json   # equals provenance/run_metadata.json inputSnapshotSha256",
    "```",
    "",
    "## Reproduce",
    "```",
    "git clone https://github.com/citizenclimate-net/pv-r-engine",
    sprintf("cd pv-r-engine && git checkout %s", commit %||% "<commit>"),
    "Rscript -e \"renv::restore(prompt=FALSE)\"",
    "# 1) Recompute Pillar 4 (geodiv) and Pillar 5 (landscapemetrics) from the shipped rasters:",
    "Rscript R/sat_reproduce.R verify /path/to/this/bundle",
    "# 2) Re-run the whole pipeline from the recorded scene list (downloads Sentinel-2 again):",
    "Rscript R/sat_reproduce.R rerun /path/to/this/bundle",
    "```",
    "",
    "Sources: Sentinel-2 L2A Collection 1 (Copernicus, via Element 84 Earth Search / AWS Open Data);",
    "Impact Observatory / Esri 10 m annual land use / land cover v02 (CC BY 4.0, via Microsoft Planetary Computer)."
  ), file.path(base, "README.md"))

  # ── zip + base64 ──────────────────────────────────────────────────────────
  zip_path <- file.path(runs_dir, paste0("sat_", run_id, ".zip"))
  unlink(zip_path)
  old <- getwd(); setwd(base); on.exit(setwd(old), add = TRUE)
  utils::zip(zipfile = zip_path, files = ".", flags = "-r9Xq")
  setwd(old)

  raw <- readBin(zip_path, "raw", n = file.info(zip_path)$size)
  list(
    zipBase64 = jsonlite::base64_enc(raw),
    renvLockSha256 = if (is.na(renv_sha)) NULL else renv_sha,
    codeCommitSha = if (is.na(commit)) NULL else commit,
    hostFingerprint = host,
    sizeBytes = length(raw)
  )
}
