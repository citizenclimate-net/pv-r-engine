# Pillar 4 — Habitat Health (PV Nature Methodology §1.5.4, Eq. 6).
#
#   1. Sentinel-2 L2A scenes over the site for a fixed three-month window
#      chosen to reflect peak vegetation cover.
#   2. Per scene: mask pixels whose L2A cloud probability exceeds the project's
#      threshold (plus SCL no-data / saturated / cloud-shadow / cloud / cirrus),
#      then NDVI = (B08 − B04) / (B08 + B04) on the 10 m grid.
#   3. Per-pixel median NDVI over the window → the site's NDVI raster.
#   4. P4(t) = z05 / σ_NDVI, where z05 is the NDVI height at 5 % of the bearing
#      area curve (the 95th percentile) and σ the standard deviation. geodiv
#      defines sbi = Sq / z05, so P4 = 1 / geodiv::sbi(ndvi) — computed with
#      geodiv, never reimplemented.
#
# The window is a per-project sampling-plan parameter verified by the PV
# Nature TRP and must stay the same every year. When the project hasn't set
# one, `p4_auto_season` proposes it from a monthly NDVI profile; the Cloud
# Function then pins it on the project so later years reuse it.

# SCL classes always masked: 0 no data, 1 saturated/defective, 3 cloud shadow,
# 8 cloud medium probability, 9 cloud high probability, 10 thin cirrus.
P4_SCL_MASK <- c(0, 1, 3, 8, 9, 10)
P4_MAX_SCENE_CLOUD <- 90   # skip scenes whose tile-level cloud cover is above this

season_window <- function(year, start_month) {
  start <- as.Date(sprintf("%d-%02d-01", as.integer(year), as.integer(start_month)))
  end <- seq(start, by = "3 months", length.out = 2)[2] - 1
  list(start = start, end = end)
}

s2_search <- function(site, start, end, max_cloud = P4_MAX_SCENE_CLOUD) {
  feats <- stac_search(SAT_S2_STAC, list(
    collections = list(SAT_S2_COLLECTION),
    bbox = as.list(site$bboxLL),
    datetime = sprintf("%sT00:00:00Z/%sT23:59:59Z", start, end),
    limit = 100
  ))
  Filter(function(f) {
    cc <- f$properties[["eo:cloud_cover"]]
    is.null(cc) || cc <= max_cloud
  }, feats)
}

#' Group items into acquisitions: the same overpass appears once per MGRS tile
#' where tiles overlap, so tiles from one date + platform are mosaicked.
group_acquisitions <- function(items) {
  key <- vapply(items, function(f) {
    paste(substr(f$properties$datetime, 1, 10), f$properties$platform %||% "")
  }, character(1))
  split(items, key)
}

#' Masked NDVI for one acquisition, resampled onto the site's 10 m grid and
#' written to `out_file`. Returns per-acquisition stats (no SpatRaster crosses
#' the fork boundary). `agg` > 1 aggregates to a coarser grid (used only for
#' the cheap auto-season profile).
p4_acquisition_ndvi <- function(items, site, cloud_thr, out_file, template = site$template) {
  layers <- list()
  ids <- character()
  for (it in items) {
    crs <- item_crs(it)
    if (is.na(crs)) next
    e <- site_extent_in(site, crs)
    a <- it$assets
    if (is.null(a$red) || is.null(a$nir) || is.null(a$cloud) || is.null(a$scl)) next

    cld <- tryCatch(read_cog_window(a$cloud$href, e), error = function(err) NULL)
    if (is.null(cld)) next
    # Skip the 10 m reads when the window is (nearly) all cloud.
    cloudy_share <- as.numeric(terra::global(cld > cloud_thr, "mean", na.rm = TRUE)[1, 1])
    if (is.finite(cloudy_share) && cloudy_share > 0.98) { ids <- c(ids, it$id); next }

    red <- read_cog_window(a$red$href, e)
    nir <- read_cog_window(a$nir$href, e)
    scl <- read_cog_window(a$scl$href, e)

    # terra applies the COG scale/offset (0.0001, −0.1), so DN 0 (no data)
    # reads as −0.1; drop it. Clamp tiny negatives from the offset to 0.
    red[red <= -0.0999] <- NA
    nir[nir <= -0.0999] <- NA
    red <- terra::clamp(red, lower = 0, values = TRUE)
    nir <- terra::clamp(nir, lower = 0, values = TRUE)

    cld10 <- terra::resample(cld, red, method = "near")
    scl10 <- terra::resample(scl, red, method = "near")
    bad <- (cld10 > cloud_thr) | (scl10 %in% P4_SCL_MASK)

    ndvi <- (nir - red) / (nir + red)
    ndvi <- terra::mask(ndvi, bad, maskvalues = TRUE)
    ndvi <- terra::clamp(ndvi, lower = -1, upper = 1, values = FALSE)
    layers[[length(layers) + 1]] <- terra::project(ndvi, template, method = "near")
    ids <- c(ids, it$id)
  }
  if (length(layers) == 0) return(list(file = NA_character_, ids = ids, clearPixels = 0))
  merged <- if (length(layers) == 1) layers[[1]] else do.call(terra::merge, unname(layers))
  merged <- terra::mask(merged, terra::resample(site$mask, template, method = "near"))
  clear <- as.numeric(terra::global(merged, "notNA")[1, 1])
  if (clear == 0) return(list(file = NA_character_, ids = ids, clearPixels = 0))
  terra::writeRaster(merged, out_file, overwrite = TRUE, datatype = "FLT4S")
  list(file = out_file, ids = ids, clearPixels = clear)
}

#' Propose the three-month window with the highest median NDVI, from a monthly
#' profile of the most recent complete calendar year (≤ 2 clearest scenes a
#' month, read on a ≤ 60 m grid to keep it cheap). Returned with the profile so
#' the TRP can review the choice.
p4_auto_season <- function(site, year, cloud_thr, today = Sys.Date()) {
  this_year <- as.integer(format(today, "%Y"))
  profile_year <- if (as.integer(year) < this_year) as.integer(year) else this_year - 1L
  feats <- s2_search(site, as.Date(sprintf("%d-01-01", profile_year)),
                     as.Date(sprintf("%d-12-31", profile_year)), max_cloud = 50)
  if (length(feats) == 0) sat_stop("No Sentinel-2 scenes found to choose the NDVI season.")

  fact <- max(1, min(6, ceiling(max(dim(site$template)[1:2]) / 150)))
  coarse <- if (fact > 1) terra::aggregate(site$template, fact = fact) else site$template
  acq <- group_acquisitions(feats)
  month_of <- function(k) as.integer(substr(k, 6, 7))
  cc_of <- function(g) mean(vapply(g, function(f) f$properties[["eo:cloud_cover"]] %||% 100, numeric(1)))
  picked <- list()
  for (m in 1:12) {
    keys <- names(acq)[vapply(names(acq), month_of, integer(1)) == m]
    if (length(keys) == 0) next
    keys <- keys[order(vapply(acq[keys], cc_of, numeric(1)))][seq_len(min(2, length(keys)))]
    for (k in keys) picked[[k]] <- acq[[k]]
  }

  dir <- file.path(SAT_WORKDIR, paste0("profile_", as.integer(Sys.time())))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  res <- sat_map(names(picked), function(k) {
    out <- tryCatch(p4_acquisition_ndvi(picked[[k]], site, cloud_thr,
                                        file.path(dir, paste0(gsub("[^0-9A-Za-z]", "_", k), ".tif")),
                                        template = coarse),
                    error = function(e) list(file = NA_character_, clearPixels = 0))
    out$key <- k
    out
  })

  site_cells <- as.numeric(terra::global(terra::resample(site$mask, coarse, method = "near"), "notNA")[1, 1])
  profile <- lapply(1:12, function(m) {
    rs <- Filter(function(r) month_of(r$key) == m && !is.na(r$file), res)
    vals <- unlist(lapply(rs, function(r) terra::values(terra::rast(r$file), na.rm = TRUE)))
    clear <- if (length(rs)) max(vapply(rs, function(r) r$clearPixels, numeric(1))) / site_cells else 0
    list(month = m,
         ndviMedian = if (length(vals)) stats::median(vals) else NA_real_,
         clearFraction = clear,
         scenes = length(Filter(function(r) month_of(r$key) == m, res)))
  })

  ndvi <- vapply(profile, function(p) if (p$clearFraction >= 0.2) p$ndviMedian else NA_real_, numeric(1))
  scores <- vapply(1:12, function(m) {
    w <- ndvi[((m - 1 + 0:2) %% 12) + 1]
    if (sum(!is.na(w)) < 2) NA_real_ else mean(w, na.rm = TRUE)
  }, numeric(1))
  if (all(is.na(scores))) {
    sat_stop("Too much cloud to choose an NDVI season automatically; set the season start month manually.")
  }
  list(startMonth = which.max(scores), autoSelected = TRUE, profileYear = profile_year,
       monthlyProfile = profile, windowScores = as.list(round(scores, 4)))
}

#' Pillar 4 for one monitoring year.
#' @param season_start_month 1–12, or NULL to auto-select (see p4_auto_season).
#' @param item_ids optional recorded scene ids (re-run from an audit bundle).
pillar4_habitat_health <- function(site, year, season_start_month = NULL,
                                   cloud_prob_threshold = 40, item_ids = NULL,
                                   out_dir = tempfile("p4_"), today = Sys.Date()) {
  t0 <- Sys.time()
  season <- if (is.null(season_start_month)) {
    p4_auto_season(site, year, cloud_prob_threshold, today)
  } else {
    list(startMonth = as.integer(season_start_month), autoSelected = FALSE)
  }
  win <- season_window(year, season$startMonth)
  if (is.null(item_ids) && win$end >= today) {
    sat_stop(sprintf("The NDVI window %s to %s hasn't finished yet.", win$start, win$end))
  }

  items <- if (is.null(item_ids)) s2_search(site, win$start, win$end)
           else stac_get_items(SAT_S2_STAC, SAT_S2_COLLECTION, item_ids)
  if (length(items) == 0) sat_stop(sprintf("No Sentinel-2 scenes over the site between %s and %s.", win$start, win$end))

  dir.create(file.path(out_dir, "scenes"), recursive = TRUE, showWarnings = FALSE)
  acq <- group_acquisitions(items)
  res <- sat_map(names(acq), function(k) {
    out <- tryCatch(p4_acquisition_ndvi(acq[[k]], site, cloud_prob_threshold,
                                        file.path(out_dir, "scenes", paste0(gsub("[^0-9A-Za-z]", "_", k), ".tif"))),
                    error = function(e) list(file = NA_character_, ids = character(), clearPixels = 0,
                                             error = conditionMessage(e)))
    out$key <- k
    out
  })
  used <- Filter(function(r) !is.na(r$file), res)
  if (length(used) == 0) sat_stop("Every Sentinel-2 scene in the window was cloud-masked over the site.")

  stack <- terra::rast(vapply(used, function(r) r$file, character(1)))
  ndvi_median <- terra::app(stack, stats::median, na.rm = TRUE)
  valid_count <- terra::app(stack, function(v) sum(!is.na(v)))
  ndvi_median <- terra::mask(ndvi_median, site$mask)
  valid_count <- terra::mask(valid_count, site$mask)
  names(ndvi_median) <- "ndvi_median"
  names(valid_count) <- "valid_observations"

  vals <- terra::values(ndvi_median, na.rm = TRUE)
  pixels_valid <- length(vals)
  if (pixels_valid < 4) sat_stop("Too few cloud-free pixels inside the site to compute Pillar 4.")

  sbi <- geodiv::sbi(ndvi_median)
  sq <- geodiv::sq(ndvi_median)
  z05 <- geodiv::height_ba(ndvi_median, 0.05)
  p4 <- if (is.finite(sbi) && sbi != 0) 1 / sbi else NA_real_
  valid_pct <- 100 * pixels_valid / site$cellsInSite

  ndvi_file <- file.path(out_dir, "ndvi_median.tif")
  count_file <- file.path(out_dir, "ndvi_valid_count.tif")
  terra::writeRaster(ndvi_median, ndvi_file, overwrite = TRUE, datatype = "FLT4S")
  terra::writeRaster(valid_count, count_file, overwrite = TRUE, datatype = "INT2U")

  scenes <- do.call(rbind, lapply(items, function(f) data.frame(
    itemId = f$id,
    datetime = f$properties$datetime,
    platform = f$properties$platform %||% NA,
    mgrsTile = f$properties[["s2:mgrs_tile"]] %||% f$properties[["grid:code"]] %||% NA,
    sceneCloudCover = f$properties[["eo:cloud_cover"]] %||% NA,
    processingBaseline = f$properties[["s2:processing_baseline"]] %||% NA,
    usedInComposite = f$id %in% unlist(lapply(used, function(r) r$ids)),
    stringsAsFactors = FALSE)))

  flags <- character()
  if (valid_pct < 80) flags <- c(flags, "low_clear_coverage")
  if (!is.finite(z05) || z05 <= 0) flags <- c(flags, "non_positive_ndvi_p95")
  if (length(used) < 3) flags <- c(flags, "few_clear_acquisitions")

  result <- list(
    value = p4,
    sbi = sbi,
    sdNdvi = sq,
    z05 = z05,
    method = "P4 = z05 / sd(NDVI) = 1 / geodiv::sbi(median NDVI) (Methodology Eq. 6)",
    ndvi = list(
      mean = mean(vals), median = stats::median(vals),
      p05 = unname(stats::quantile(vals, 0.05)), p95 = unname(stats::quantile(vals, 0.95)),
      min = min(vals), max = max(vals)
    ),
    pixelsInSite = site$cellsInSite,
    pixelsValid = pixels_valid,
    validPixelPct = valid_pct,
    scenesFound = length(items),
    acquisitionsFound = length(acq),
    acquisitionsUsed = length(used),
    season = c(list(startMonth = season$startMonth,
                    startDate = format(win$start), endDate = format(win$end)),
               season[setdiff(names(season), "startMonth")]),
    cloudProbThreshold = cloud_prob_threshold,
    maskedSclClasses = P4_SCL_MASK,
    source = list(stac = SAT_S2_STAC, collection = SAT_S2_COLLECTION,
                  cloudMask = "Sentinel-2 L2A cloud probability (CLD_20m / MSK_CLDPRB)"),
    grid = list(epsg = site$epsg, resolutionM = SAT_RES_M),
    flags = as.list(flags),
    durationSec = as.numeric(difftime(Sys.time(), t0, units = "secs"))
  )
  list(result = result, files = list(ndvi_median = ndvi_file, ndvi_valid_count = count_file),
       scenes = scenes)
}
