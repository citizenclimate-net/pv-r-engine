# PV Nature — Pillar Metrics R engine (plumber API)
#
# Deployed on the existing Hetzner box alongside BirdNET-Analyzer, fronted by
# nginx + Let's Encrypt and run as the `pv-r-engine` systemd service. Cloud
# Functions (runPillarMetrics) call POST /run with an X-API-Key header — exactly
# the shape analyzeBirdAudio uses for BirdNET.
#
# Open-source per PV Nature DAP Requirements §2.1. A VVB clones this repo at the
# commit SHA recorded in metricsRuns/{runId}, runs renv::restore(), and
# reproduces every number with `Rscript R/pillar1.R inputs/species_count_matrix.csv`.

library(plumber)
library(jsonlite)

source("R/matrix.R")
source("R/pillar1.R")
source("R/pillar2.R")
source("R/pillar3.R")

# Determinism: all iNEXT bootstrap draws are reproducible (DAP §2.1).
set.seed(42)

API_KEY <- trimws(readLines("/etc/cc-pv-r/api-key", warn = FALSE)[1])

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
function() {
  list(
    status = "ok",
    rVersion = R.version.string,
    packageVersions = pv_package_versions()
  )
}

#* Compute Pillar Metrics for one project/year.
#* @post /run
#* @serializer unboxedJSON
function(req, res) {
  payload <- tryCatch(
    jsonlite::fromJSON(req$postBody, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(payload) || is.null(payload$speciesCountMatrix)) {
    res$status <- 400
    return(list(error = "missing speciesCountMatrix"))
  }

  run_id   <- payload$runId %||% "run_local"
  pillars  <- unlist(payload$pillars %||% list(1, 2, 3))
  matrix_by_group <- parse_species_matrix(payload$speciesCountMatrix)
  taxonomy <- parse_taxonomy_tree(payload$taxonomyTree)

  if (length(matrix_by_group) == 0) {
    res$status <- 400
    return(list(error = "empty species count matrix"))
  }

  out <- list()
  if (1 %in% pillars) out[["1"]] <- pillar1_species_richness(matrix_by_group)
  if (2 %in% pillars) out[["2"]] <- pillar2_species_diversity(matrix_by_group)
  if (3 %in% pillars) out[["3"]] <- pillar3_taxonomic_dissimilarity(matrix_by_group, taxonomy)

  list(
    runId           = run_id,
    pillars         = out,
    rVersion        = R.version.string,
    packageVersions = pv_package_versions(),
    hostFingerprint = Sys.getenv("PV_HOST_FINGERPRINT", unset = Sys.info()[["nodename"]]),
    deterministic   = TRUE,
    computedAt      = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
}
