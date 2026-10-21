# PV Nature — satellite pillars service (Pillars 4 and 5), plumber API.
#
# Runs as its own systemd service (pv-sat-engine, 127.0.0.1:8002) next to the
# Pillars 1–3 engine (api.R, :8001), so a multi-minute Sentinel-2 run never
# blocks a species run. nginx exposes it under /sat/ on the same host with the
# same X-API-Key. Cloud Functions (runSatellitePillars) call POST /sat/run.
#
# Open-source per PV Nature DAP Requirements §2.1: a VVB re-derives every number
# from the audit bundle with R/sat_reproduce.R.

library(plumber)
library(jsonlite)

source("R/matrix.R")      # %||%
source("R/bundle.R")      # .sys
source("R/sat_common.R")
source("R/pillar4.R")
source("R/pillar5.R")
source("R/sat_bundle.R")

sat_configure_gdal()

API_KEY <- trimws(readLines(Sys.getenv("PV_API_KEY_FILE", "/etc/cc-pv-r/api-key"), warn = FALSE)[1])

#* @filter auth
function(req, res) {
  provided <- req$HTTP_X_API_KEY
  if (is.null(provided) || !identical(provided, API_KEY)) {
    res$status <- 401
    return(list(error = "unauthorized"))
  }
  plumber::forward()
}

#* Health check
#* @get /health
#* @serializer unboxedJSON
function() {
  list(
    status = "ok",
    service = "pv-sat-engine",
    rVersion = R.version.string,
    packageVersions = pv_sat_versions(),
    sources = list(sentinel2 = paste(SAT_S2_STAC, SAT_S2_COLLECTION),
                   landcover = paste(SAT_LC_STAC, SAT_LC_COLLECTION)),
    workers = SAT_WORKERS
  )
}

#* Compute Pillars 4 and/or 5 for one project/year.
#* @post /run
#* @serializer unboxedJSON list(digits = NA)
function(req, res) {
  payload <- tryCatch(jsonlite::fromJSON(req$postBody, simplifyVector = FALSE),
                      error = function(e) NULL)
  if (is.null(payload) || is.null(payload$boundaryGeoJSON) || is.null(payload$year)) {
    res$status <- 400
    return(list(error = "missing boundaryGeoJSON or year"))
  }
  run_id  <- payload$runId %||% "sat_local"
  year    <- as.integer(payload$year)
  pillars <- as.integer(unlist(payload$pillars %||% list(4, 5)))
  out_dir <- file.path(SAT_WORKDIR, paste0("run_", gsub("[^0-9A-Za-z_-]", "", run_id)))
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  site <- tryCatch(sat_site(payload$boundaryGeoJSON), sat_user_error = function(e) e)
  if (inherits(site, "sat_user_error")) {
    res$status <- 422
    return(list(error = conditionMessage(site)))
  }

  errors <- list()
  run_pillar <- function(key, expr) {
    tryCatch(expr,
      sat_user_error = function(e) { errors[[key]] <<- conditionMessage(e); NULL },
      error = function(e) {
        message(sprintf("pillar %s failed: %s", key, conditionMessage(e)))
        errors[[key]] <<- paste("internal error:", conditionMessage(e))
        NULL
      })
  }

  p4 <- if (4L %in% pillars) run_pillar("4", pillar4_habitat_health(
    site, year,
    season_start_month = payload$ndviSeasonStartMonth,
    cloud_prob_threshold = as.numeric(payload$cloudProbThreshold %||% 40),
    item_ids = if (length(payload$s2ItemIds)) unlist(payload$s2ItemIds) else NULL,
    out_dir = file.path(out_dir, "p4"))) else NULL
  p5 <- if (5L %in% pillars) run_pillar("5", pillar5_habitat_structure(
    site, year,
    low_use_classes = payload$habitatLowUseClasses %||% P5_DEFAULT_LOW_USE,
    item_ids = if (length(payload$landcoverItemIds)) unlist(payload$landcoverItemIds) else NULL,
    out_dir = file.path(out_dir, "p5"))) else NULL

  out <- list()
  if (!is.null(p4)) out[["4"]] <- p4$result
  if (!is.null(p5)) out[["5"]] <- p5$result
  if (length(out) == 0) {
    res$status <- 422
    return(list(error = paste(unlist(errors), collapse = " | "), errors = errors))
  }

  computed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  bundle <- tryCatch(
    build_sat_audit_bundle(run_id, site, payload, p4, p5, out, list(computedAt = computed_at)),
    error = function(e) { message("build_sat_audit_bundle failed: ", conditionMessage(e)); NULL })

  list(
    runId                = run_id,
    pillars              = out,
    errors               = errors,
    site                 = list(areaHa = site$areaHa, epsg = site$epsg, cells = site$cellsInSite),
    rVersion             = R.version.string,
    packageVersions      = pv_sat_versions(),
    hostFingerprint      = Sys.getenv("PV_HOST_FINGERPRINT", unset = Sys.info()[["nodename"]]),
    renvLockSha256       = if (is.null(bundle)) NULL else bundle$renvLockSha256,
    codeCommitSha        = if (is.null(bundle)) NULL else bundle$codeCommitSha,
    auditBundleZipBase64 = if (is.null(bundle)) NULL else bundle$zipBase64,
    auditBundleSizeBytes = if (is.null(bundle)) NULL else bundle$sizeBytes,
    deterministic        = TRUE,
    computedAt           = computed_at
  )
}
