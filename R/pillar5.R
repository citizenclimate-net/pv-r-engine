# Pillar 5 — Habitat Spatial Structure (PV Nature Methodology §1.5.5, Eq. 7).
#
#   1. A habitat map of the site classified into 'low intensity human use' vs
#      'intensive human use', on a 10 m raster.
#   2. P5(t) = 100 × Σ core area of low-use patches / site area, with the core
#      being the part of a patch more than 10 m (one cell) from its edge —
#      landscapemetrics::lsm_c_cpland(edge_depth = 1) on the low-use class.
#
# Habitat source: the Impact Observatory / Esri 10 m annual land use / land
# cover (a Sentinel-2-derived classification), latest year at or before the
# monitoring year. Which classes count as low-intensity use is a per-project
# choice agreed at baseline and reviewed by the PV Nature TRP (e.g. plantation
# forestry is 'Trees' in land cover but intensive use), so it is an input.
#
# Computed at the biodiversity baseline and every 5 years after; the Cloud
# Function decides when, R just computes.

# Impact Observatory LULC v02 class codes.
P5_LC_CLASSES <- c(`1` = "Water", `2` = "Trees", `4` = "Flooded vegetation", `5` = "Crops",
                   `7` = "Built area", `8` = "Bare ground", `9` = "Snow/ice", `10` = "Clouds",
                   `11` = "Rangeland")
P5_LC_NODATA <- c(0, 10)                       # no data, clouds → excluded from the landscape
P5_DEFAULT_LOW_USE <- c(1, 2, 4, 9, 11)

lc_sas_token <- function() {
  res <- httr::RETRY("GET", SAT_LC_SAS_URL, times = 4, pause_base = 2, quiet = TRUE, httr::timeout(30))
  if (httr::http_error(res)) sat_stop("Could not get a Planetary Computer access token for land cover.")
  jsonlite::fromJSON(httr::content(res, as = "text", encoding = "UTF-8"))$token
}

#' Pillar 5 for one monitoring year.
#' @param low_use_classes land cover codes counted as low-intensity human use.
#' @param item_ids optional recorded land cover item ids (re-run from a bundle).
pillar5_habitat_structure <- function(site, year, low_use_classes = P5_DEFAULT_LOW_USE,
                                      item_ids = NULL, out_dir = tempfile("p5_")) {
  t0 <- Sys.time()
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  low_use_classes <- as.integer(unlist(low_use_classes))
  if (length(low_use_classes) == 0) sat_stop("No land cover classes are marked as low-intensity human use.")

  items <- if (is.null(item_ids)) {
    stac_search(SAT_LC_STAC, list(collections = list(SAT_LC_COLLECTION),
                                  bbox = as.list(site$bboxLL), limit = 100))
  } else {
    stac_get_items(SAT_LC_STAC, SAT_LC_COLLECTION, item_ids)
  }
  if (length(items) == 0) sat_stop("No land cover data covers the site.")
  item_year <- vapply(items, function(f) {
    as.integer(substr(f$properties$start_datetime %||% f$properties$datetime, 1, 4))
  }, integer(1))
  eligible <- item_year[item_year <= as.integer(year)]
  lc_year <- if (length(eligible)) max(eligible) else max(item_year)
  sel <- items[item_year == lc_year]

  token <- lc_sas_token()
  layers <- lapply(sel, function(f) {
    crs <- item_crs(f)
    e <- site_extent_in(site, crs, buffer = 40, snap = 10)
    r <- terra::rast(paste0("/vsicurl/", f$assets$data$href, "?", token))
    terra::project(terra::crop(r, e, snap = "out"), site$template, method = "near")
  })
  lc <- if (length(layers) == 1) layers[[1]] else do.call(terra::merge, unname(layers))
  lc <- terra::mask(lc, site$mask)
  lc[lc %in% P5_LC_NODATA] <- NA
  names(lc) <- "landcover"

  # 1 = low-intensity human use, 2 = intensive human use.
  habitat <- terra::ifel(lc %in% low_use_classes, 1L, 2L)
  habitat <- terra::mask(habitat, lc)
  names(habitat) <- "habitat"

  landscape_cells <- as.numeric(terra::global(habitat, "notNA")[1, 1])
  if (landscape_cells < 4) sat_stop("The land cover map has no usable pixels inside the site.")

  cp <- landscapemetrics::lsm_c_cpland(habitat, directions = 8,
                                       consider_boundary = FALSE, edge_depth = 1)
  p5 <- if (any(cp$class == 1)) cp$value[cp$class == 1][1] else 0

  cell_ha <- (SAT_RES_M * SAT_RES_M) / 10000
  fq <- terra::freq(lc)
  class_area <- list()
  for (i in seq_len(nrow(fq))) {
    code <- as.character(fq$value[i])
    class_area[[code]] <- list(code = as.integer(code),
                               name = if (code %in% names(P5_LC_CLASSES)) unname(P5_LC_CLASSES[[code]]) else "Unknown",
                               areaHa = fq$count[i] * cell_ha,
                               lowUse = as.integer(code) %in% low_use_classes)
  }
  low_cells <- sum(terra::values(habitat, na.rm = TRUE) == 1)

  lc_file <- file.path(out_dir, "landcover_10m.tif")
  hab_file <- file.path(out_dir, "habitat_10m.tif")
  terra::writeRaster(lc, lc_file, overwrite = TRUE, datatype = "INT1U")
  terra::writeRaster(habitat, hab_file, overwrite = TRUE, datatype = "INT1U")

  flags <- character()
  if (lc_year < as.integer(year)) flags <- c(flags, "landcover_older_than_monitoring_year")
  if (landscape_cells < 0.9 * site$cellsInSite) flags <- c(flags, "landcover_gaps")

  items_df <- do.call(rbind, lapply(sel, function(f) data.frame(
    itemId = f$id, year = lc_year, href = f$assets$data$href, stringsAsFactors = FALSE)))

  result <- list(
    value = p5,
    method = "P5 = landscapemetrics::lsm_c_cpland(class = low-intensity use, edge_depth = 1 cell = 10 m) (Methodology Eq. 7)",
    lowUseClasses = as.list(low_use_classes),
    lowUseAreaHa = low_cells * cell_ha,
    coreAreaHa = p5 / 100 * landscape_cells * cell_ha,
    landscapeAreaHa = landscape_cells * cell_ha,
    siteAreaHa = site$areaHa,
    classAreas = unname(class_area),
    landcover = list(source = "Impact Observatory / Esri 10 m annual land use / land cover v02 (Sentinel-2)",
                     stac = SAT_LC_STAC, collection = SAT_LC_COLLECTION, year = lc_year,
                     yearsBehind = as.integer(year) - lc_year,
                     licence = "CC BY 4.0"),
    cplandParams = list(directions = 8, considerBoundary = FALSE, edgeDepthCells = 1, edgeDepthM = 10),
    grid = list(epsg = site$epsg, resolutionM = SAT_RES_M),
    requiresTrpReview = TRUE,
    flags = as.list(flags),
    durationSec = as.numeric(difftime(Sys.time(), t0, units = "secs"))
  )
  list(result = result, files = list(landcover_10m = lc_file, habitat_10m = hab_file),
       landcoverItems = items_df)
}
