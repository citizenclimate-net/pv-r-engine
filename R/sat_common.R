# Shared helpers for the satellite pillars (4 and 5): GDAL/HTTP settings, the
# site boundary → 10 m analysis grid, and a minimal STAC client.
#
# Data sources (all free and open, no account needed):
#   - Sentinel-2 L2A Collection 1 COGs on AWS Open Data, searched through
#     Element 84 Earth Search. Assets used: red (B04), nir (B08), scl, and
#     cloud (CLD_20m = the L2A cloud-probability layer, 0–100 %).
#   - Impact Observatory / Esri 10 m annual land use / land cover (v02), a
#     Sentinel-2-derived classification, from Microsoft Planetary Computer.
#
# Every number is computed in R on a 10 m grid in the UTM zone of the site
# centroid; nothing is reimplemented outside terra / geodiv / landscapemetrics.

library(terra)
library(jsonlite)
library(httr)

SAT_S2_STAC        <- Sys.getenv("PV_S2_STAC_URL", "https://earth-search.aws.element84.com/v1")
SAT_S2_COLLECTION  <- "sentinel-2-c1-l2a"
SAT_LC_STAC        <- Sys.getenv("PV_LC_STAC_URL", "https://planetarycomputer.microsoft.com/api/stac/v1")
SAT_LC_COLLECTION  <- "io-lulc-annual-v02"
SAT_LC_SAS_URL     <- "https://planetarycomputer.microsoft.com/api/sas/v1/token/io-lulc-annual-v02"
SAT_RES_M          <- 10
SAT_MAX_AREA_HA    <- as.numeric(Sys.getenv("PV_SAT_MAX_AREA_HA", "50000"))
SAT_WORKDIR        <- Sys.getenv("PV_SAT_WORKDIR", file.path(tempdir(), "cc-pv-sat"))
# Concurrent scene reads. Reads are network-bound, so several forked workers
# help even on a 1-vCPU box. Forking is Linux-only here (macOS GDAL+fork is
# unsafe), so local runs fall back to sequential.
SAT_WORKERS <- if (.Platform$OS.type == "unix" && Sys.info()[["sysname"]] == "Linux") {
  as.integer(Sys.getenv("PV_SAT_WORKERS", "4"))
} else 1L

#' A user-facing failure (bad boundary, season not finished, no imagery):
#' the API returns it as a 422 with the message instead of a 500.
sat_stop <- function(msg) {
  stop(structure(class = c("sat_user_error", "error", "condition"),
                 list(message = msg, call = NULL)))
}

sat_configure_gdal <- function() {
  terra::setGDALconfig(c(
    "GDAL_DISABLE_READDIR_ON_OPEN=EMPTY_DIR",
    "CPL_VSIL_CURL_ALLOWED_EXTENSIONS=.tif,.TIF,.tiff",
    "GDAL_HTTP_MAX_RETRY=4",
    "GDAL_HTTP_RETRY_DELAY=2",
    "GDAL_HTTP_TIMEOUT=60",
    "GDAL_HTTP_MULTIRANGE=YES",
    "GDAL_HTTP_MERGE_CONSECUTIVE_RANGES=YES",
    "VSI_CACHE=TRUE",
    "GDAL_CACHEMAX=256"
  ))
  dir.create(SAT_WORKDIR, recursive = TRUE, showWarnings = FALSE)
  terra::terraOptions(tempdir = SAT_WORKDIR, memfrac = 0.5, progress = 0)
}

#' Versions of every package that touches the satellite numbers.
pv_sat_versions <- function() {
  pkgs <- c("terra", "geodiv", "landscapemetrics", "httr", "jsonlite")
  vers <- list()
  for (p in pkgs) {
    vers[[p]] <- tryCatch(as.character(utils::packageVersion(p)), error = function(e) NA_character_)
  }
  vers[["GDAL"]] <- tryCatch(terra::gdal(), error = function(e) NA_character_)
  vers
}

# ── Site boundary → analysis grid ──────────────────────────────────────────────

#' UTM EPSG code for a lon/lat point (WGS84 / UTM north 326xx, south 327xx).
utm_epsg <- function(lon, lat) {
  zone <- floor((lon + 180) / 6) + 1
  zone <- max(1, min(60, zone))
  if (lat >= 0) 32600 + zone else 32700 + zone
}

#' Parse the site boundary (WGS84 GeoJSON geometry string) and build the
#' analysis grid: a 10 m raster template in the site's UTM zone, snapped to
#' 10 m multiples so it lines up with the Sentinel-2 pixel grid, plus a site
#' mask (1 inside the boundary, NA outside).
sat_site <- function(geojson) {
  if (!is.character(geojson) || length(geojson) != 1 || !nzchar(geojson)) {
    sat_stop("Site boundary is missing.")
  }
  f <- tempfile(fileext = ".geojson")
  on.exit(unlink(f), add = TRUE)
  writeLines(geojson, f)
  v <- tryCatch(terra::vect(f), error = function(e) sat_stop("Site boundary is not valid GeoJSON."))
  if (nrow(v) == 0 || terra::geomtype(v) != "polygons") sat_stop("Site boundary has no polygons.")
  terra::crs(v) <- "EPSG:4326"
  v <- terra::aggregate(terra::makeValid(v))

  area_ha <- sum(terra::expanse(v, unit = "ha"))
  if (!is.finite(area_ha) || area_ha <= 0) sat_stop("Site boundary has zero area.")
  if (area_ha > SAT_MAX_AREA_HA) {
    sat_stop(sprintf("Site is %.0f ha; satellite pillars are limited to %.0f ha per run.",
                     area_ha, SAT_MAX_AREA_HA))
  }

  ll_ext <- terra::ext(v)
  lon <- unname((ll_ext$xmin + ll_ext$xmax) / 2)
  lat <- unname((ll_ext$ymin + ll_ext$ymax) / 2)
  epsg <- utm_epsg(lon, lat)
  crs <- paste0("EPSG:", epsg)
  vu <- terra::project(v, crs)

  e <- terra::ext(vu)
  snap <- function(x, f) f(x / SAT_RES_M) * SAT_RES_M
  grid_ext <- terra::ext(snap(e$xmin, floor) - SAT_RES_M, snap(e$xmax, ceiling) + SAT_RES_M,
                         snap(e$ymin, floor) - SAT_RES_M, snap(e$ymax, ceiling) + SAT_RES_M)
  template <- terra::rast(grid_ext, resolution = SAT_RES_M, crs = crs)
  mask <- terra::rasterize(vu, template, field = 1, touches = FALSE)
  cells_in_site <- as.numeric(terra::global(mask, "notNA")[1, 1])
  if (cells_in_site < 4) sat_stop("Site boundary is smaller than a few 10 m pixels.")

  list(
    vect_ll = v,
    vect_utm = vu,
    epsg = epsg,
    template = template,
    mask = mask,
    areaHa = area_ha,
    cellsInSite = cells_in_site,
    bboxLL = unname(as.numeric(c(ll_ext$xmin, ll_ext$ymin, ll_ext$xmax, ll_ext$ymax))),
    geojson = geojson
  )
}

#' The site's extent in another CRS (e.g. a Sentinel-2 tile's UTM zone),
#' buffered by `buffer` metres and snapped outward to `snap` metres so 10 m and
#' 20 m bands crop to the same footprint.
site_extent_in <- function(site, crs, buffer = 40, snap = 20) {
  e <- terra::ext(terra::project(site$vect_ll, crs))
  terra::ext(floor((e$xmin - buffer) / snap) * snap, ceiling((e$xmax + buffer) / snap) * snap,
             floor((e$ymin - buffer) / snap) * snap, ceiling((e$ymax + buffer) / snap) * snap)
}

#' The EPSG code of a STAC item (proj:epsg in older STAC, proj:code in newer).
item_crs <- function(item) {
  p <- item$properties
  if (!is.null(p[["proj:epsg"]])) return(paste0("EPSG:", p[["proj:epsg"]]))
  if (!is.null(p[["proj:code"]])) return(p[["proj:code"]])
  a <- item$assets[[1]]
  if (!is.null(a[["proj:epsg"]])) return(paste0("EPSG:", a[["proj:epsg"]]))
  if (!is.null(a[["proj:code"]])) return(a[["proj:code"]])
  NA_character_
}

#' Open a remote COG window: only the bytes covering `e` are fetched (HTTP
#' range requests through GDAL /vsicurl/).
read_cog_window <- function(href, e) {
  r <- terra::rast(paste0("/vsicurl/", href))
  terra::crop(r, e, snap = "out")
}

# ── STAC ──────────────────────────────────────────────────────────────────────

#' POST /search with pagination (follows rel="next" links, GET or POST).
stac_search <- function(api, body, max_items = 1000) {
  url <- paste0(sub("/$", "", api), "/search")
  method <- "POST"
  feats <- list()
  repeat {
    res <- httr::RETRY(method, url,
                       body = if (method == "POST") body else NULL,
                       encode = "json", times = 4, pause_base = 2, quiet = TRUE,
                       httr::timeout(90))
    if (httr::http_error(res)) {
      sat_stop(sprintf("STAC search failed (%s): %s", httr::status_code(res),
                       substr(httr::content(res, as = "text", encoding = "UTF-8"), 1, 200)))
    }
    js <- jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"),
                             simplifyVector = FALSE)
    feats <- c(feats, js$features)
    nxt <- Filter(function(l) identical(l$rel, "next"), js$links %||% list())
    if (length(nxt) == 0 || length(js$features) == 0 || length(feats) >= max_items) break
    nl <- nxt[[1]]
    url <- nl$href
    method <- toupper(nl$method %||% "GET")
    if (method == "POST") {
      body <- if (isTRUE(nl$merge)) utils::modifyList(body, nl$body %||% list()) else (nl$body %||% body)
    }
  }
  feats
}

#' Fetch specific STAC items by id (used to re-run a recorded scene list).
stac_get_items <- function(api, collection, ids) {
  lapply(ids, function(id) {
    res <- httr::RETRY("GET", sprintf("%s/collections/%s/items/%s", sub("/$", "", api), collection, id),
                       times = 4, pause_base = 2, quiet = TRUE, httr::timeout(60))
    if (httr::http_error(res)) sat_stop(sprintf("STAC item %s not found.", id))
    jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
  })
}

SAT_JOB_TIMEOUT <- as.numeric(Sys.getenv("PV_SAT_JOB_TIMEOUT", "120"))

#' Run `fun` over `xs` and return the results in order. On Linux each element
#' runs in its own forked child, up to SAT_WORKERS at a time, with a
#' SAT_JOB_TIMEOUT limit. A forked child can deadlock on network/TLS state it
#' inherited from the parent, so a child that runs over the limit is killed and
#' from then on every remaining element (and the killed one) runs in-process.
#' `fun` failing for an element yields `on_fail(x, reason)` instead of an error.
sat_map <- function(xs, fun, on_fail) {
  safe <- function(x) tryCatch(fun(x), error = function(e) on_fail(x, conditionMessage(e)))
  if (SAT_WORKERS <= 1 || length(xs) <= 1) return(lapply(xs, safe))
  out <- vector("list", length(xs))
  pending <- seq_along(xs)
  running <- list()                     # pid -> list(job, i, start)
  forking <- TRUE
  while (length(running) > 0 || (forking && length(pending) > 0)) {
    while (forking && length(running) < SAT_WORKERS && length(pending) > 0) {
      i <- pending[1]; pending <- pending[-1]
      job <- parallel::mcparallel(safe(xs[[i]]), silent = TRUE)
      running[[as.character(job$pid)]] <- list(job = job, i = i, start = Sys.time())
    }
    done <- parallel::mccollect(lapply(running, `[[`, "job"), wait = FALSE, timeout = 0.5)
    for (pid in names(done)) {
      r <- running[[pid]]
      if (is.null(r)) next
      v <- done[[pid]]
      out[[r$i]] <- if (is.list(v)) v else on_fail(xs[[r$i]], "worker process failed")
      running[[pid]] <- NULL
    }
    for (pid in names(running)) {
      r <- running[[pid]]
      if (as.numeric(difftime(Sys.time(), r$start, units = "secs")) > SAT_JOB_TIMEOUT) {
        message(sprintf("sat_map: worker %s over %d s, killing it and continuing in-process", pid, SAT_JOB_TIMEOUT))
        tools::pskill(as.integer(pid), tools::SIGKILL)
        try(parallel::mccollect(r$job, wait = TRUE, timeout = 5), silent = TRUE)
        pending <- c(pending, r$i)
        running[[pid]] <- NULL
        forking <- FALSE
      }
    }
  }
  for (i in pending) out[[i]] <- safe(xs[[i]])
  out
}
