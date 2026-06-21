# Shared helpers: convert the JSON contract into R structures + version reporting.

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Convert the speciesCountMatrix JSON
#'   { "<targetGroup>": { "<scientificName>": <count>, ... }, ... }
#' into a named list of named integer vectors (one per Target Group). This is the
#' abundance form iNEXT expects (`datatype = "abundance"`).
parse_species_matrix <- function(species_count_matrix) {
  out <- list()
  for (tg in names(species_count_matrix)) {
    counts <- species_count_matrix[[tg]]
    if (length(counts) == 0) next
    vec <- vapply(counts, function(x) as.numeric(x), numeric(1))
    names(vec) <- names(counts)
    vec <- vec[vec > 0]
    if (length(vec) > 0) out[[tg]] <- vec
  }
  out
}

#' Convert the taxonomyTree JSON (list of rows with kingdom..species, keyed by
#' scientificName) into a data frame with one column per taxonomic rank — the
#' shape vegan::taxa2dist consumes. Rows are ordered to match `species`.
parse_taxonomy_tree <- function(taxonomy_tree) {
  ranks <- c("kingdom", "phylum", "class", "order", "family", "genus", "species")
  if (is.null(taxonomy_tree) || length(taxonomy_tree) == 0) {
    return(data.frame())
  }
  rows <- lapply(taxonomy_tree, function(r) {
    vals <- vapply(ranks, function(k) {
      v <- r[[k]]
      if (is.null(v) || is.na(v)) NA_character_ else as.character(v)
    }, character(1))
    # Fall back to scientificName for the species rank if missing.
    if (is.na(vals[["species"]])) vals[["species"]] <- as.character(r$scientificName %||% NA)
    vals
  })
  df <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  rownames(df) <- vapply(taxonomy_tree, function(r) as.character(r$scientificName), character(1))
  df
}

#' Extract (estimator, lcl, ucl) for a diversity measure from an iNEXT AsyEst
#' table. Robust to version differences: in iNEXT 3.0.1 the measure is the ROW
#' NAME ("Species Richness", "Shannon diversity", ...) and CI columns are
#' "95% Lower"/"95% Upper"; older versions use a "Diversity" column and LCL/UCL.
asyest_row <- function(asy, keyword) {
  na3 <- list(estimator = NA_real_, lcl = NA_real_, ucl = NA_real_)
  if (is.null(asy) || nrow(asy) == 0) return(na3)

  ridx <- grep(keyword, rownames(asy), ignore.case = TRUE)
  if (length(ridx) == 0 && "Diversity" %in% colnames(asy)) {
    ridx <- grep(keyword, asy$Diversity, ignore.case = TRUE)
  }
  if (length(ridx) == 0) return(na3)
  ridx <- ridx[1]

  col_est <- grep("^Estimator$", colnames(asy), ignore.case = TRUE, value = TRUE)
  col_lcl <- grep("Lower|LCL", colnames(asy), ignore.case = TRUE, value = TRUE)
  col_ucl <- grep("Upper|UCL", colnames(asy), ignore.case = TRUE, value = TRUE)

  num <- function(x) suppressWarnings(as.numeric(x))
  est <- if (length(col_est)) num(asy[ridx, col_est[1]]) else NA_real_
  lcl <- if (length(col_lcl)) num(asy[ridx, col_lcl[1]]) else est
  ucl <- if (length(col_ucl)) num(asy[ridx, col_ucl[1]]) else est
  list(estimator = est, lcl = lcl, ucl = ucl)
}

#' Versions of the canonical packages, pinned in renv.lock and recorded in the
#' audit trail so a VVB can reproduce the exact computation.
pv_package_versions <- function() {
  pkgs <- c("iNEXT", "vegan", "geodiv", "landscapemetrics")
  vers <- list()
  for (p in pkgs) {
    vers[[p]] <- tryCatch(as.character(utils::packageVersion(p)), error = function(e) NA_character_)
  }
  vers
}
