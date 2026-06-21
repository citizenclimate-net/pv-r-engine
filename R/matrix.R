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
