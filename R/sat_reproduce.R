# Reproduce a satellite audit bundle (Pillars 4–5). Run from the repo root at
# the commit recorded in the bundle's provenance/code_commit_sha.txt:
#
#   Rscript R/sat_reproduce.R verify <bundle_dir>   # recompute from the shipped rasters (seconds)
#   Rscript R/sat_reproduce.R rerun  <bundle_dir>   # re-run from the recorded scene list
#
# `verify` checks the input hash, then recomputes P4 = 1 / geodiv::sbi() on
# outputs/ndvi_median.tif and P5 = landscapemetrics::lsm_c_cpland() on
# outputs/habitat_10m.tif. `rerun` downloads the same Sentinel-2 scenes and land
# cover tiles again and repeats the whole pipeline.

suppressMessages({
  source("R/matrix.R")
  source("R/bundle.R")
  source("R/sat_common.R")
  source("R/pillar4.R")
  source("R/pillar5.R")
})

sha256_file <- function(path) {
  out <- .sys("sha256sum", path)
  if (is.na(out)) out <- .sys("shasum", c("-a", "256", path))
  if (is.na(out)) NA_character_ else sub("\\s.*$", "", out)
}

report <- function(label, recorded, recomputed, tol = 1e-6) {
  ok <- !is.null(recorded) && is.finite(recomputed) &&
    abs(recomputed - recorded) <= tol * max(1, abs(recorded))
  cat(sprintf("%-28s recorded=%-14s recomputed=%-14s %s\n", label,
              format(recorded %||% NA, digits = 10), format(recomputed, digits = 10),
              if (ok) "OK" else "MISMATCH"))
  ok
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2 || !args[1] %in% c("verify", "rerun")) {
  stop("usage: Rscript R/sat_reproduce.R verify|rerun <bundle_dir>")
}
mode <- args[1]
b <- normalizePath(args[2])
recorded <- jsonlite::fromJSON(file.path(b, "outputs", "satellite_pillars.json"), simplifyVector = FALSE)
meta <- jsonlite::fromJSON(file.path(b, "provenance", "run_metadata.json"), simplifyVector = FALSE)
all_ok <- TRUE

hashed <- file.path(b, "inputs", "hashed_input.json")
if (file.exists(hashed)) {
  h <- sha256_file(hashed)
  ok <- identical(h, meta$inputSnapshotSha256)
  cat(sprintf("%-28s %s\n", "input hash", if (ok) "OK" else paste("MISMATCH", h)))
  all_ok <- all_ok && ok
}

if (mode == "verify") {
  ndvi_file <- file.path(b, "outputs", "ndvi_median.tif")
  if (!is.null(recorded[["4"]]) && file.exists(ndvi_file)) {
    ndvi <- terra::rast(ndvi_file)
    all_ok <- report("Pillar 4 (1/SBI)", recorded[["4"]]$value, 1 / geodiv::sbi(ndvi)) && all_ok
  }
  hab_file <- file.path(b, "outputs", "habitat_10m.tif")
  if (!is.null(recorded[["5"]]) && file.exists(hab_file)) {
    cp <- landscapemetrics::lsm_c_cpland(terra::rast(hab_file), directions = 8,
                                         consider_boundary = FALSE, edge_depth = 1)
    p5 <- if (any(cp$class == 1)) cp$value[cp$class == 1][1] else 0
    all_ok <- report("Pillar 5 (CPLAND %)", recorded[["5"]]$value, p5) && all_ok
  }
} else {
  sat_configure_gdal()
  request <- jsonlite::fromJSON(file.path(b, "inputs", "request.json"), simplifyVector = FALSE)
  site <- sat_site(paste(readLines(file.path(b, "inputs", "site_boundary.geojson"), warn = FALSE), collapse = "\n"))
  year <- as.integer(request$year)
  if (!is.null(recorded[["4"]])) {
    scenes <- utils::read.csv(file.path(b, "inputs", "s2_scenes.csv"), stringsAsFactors = FALSE)
    p4 <- pillar4_habitat_health(site, year,
                                 season_start_month = recorded[["4"]]$season$startMonth,
                                 cloud_prob_threshold = recorded[["4"]]$cloudProbThreshold,
                                 item_ids = scenes$itemId)
    all_ok <- report("Pillar 4 (1/SBI)", recorded[["4"]]$value, p4$result$value, tol = 1e-4) && all_ok
  }
  if (!is.null(recorded[["5"]])) {
    items <- utils::read.csv(file.path(b, "inputs", "landcover_items.csv"), stringsAsFactors = FALSE)
    p5 <- pillar5_habitat_structure(site, year,
                                    low_use_classes = unlist(recorded[["5"]]$lowUseClasses),
                                    item_ids = items$itemId)
    all_ok <- report("Pillar 5 (CPLAND %)", recorded[["5"]]$value, p5$result$value, tol = 1e-4) && all_ok
  }
}

cat(if (all_ok) "\nAll checks passed.\n" else "\nSome checks failed.\n")
quit(status = if (all_ok) 0 else 1)
