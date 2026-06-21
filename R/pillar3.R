# Pillar 3 — Taxonomic Dissimilarity (Delta* and Delta+), DAP Requirements §2.3.
#
# "Calculate within-group (Delta*) and between-group (Delta+) dissimilarities
#  using the taxa2dist function and the final metric with the taxondive function,
#  both from the vegan package in R (Oksanen et al 2022). GBIF should be used as
#  the taxonomic backbone for species classification."
#
# Branch lengths: GBIF gives lineage (kingdom..species) but not phylogenetic
# distances, so taxa2dist uses equal-step distances per rank (its default). If
# Plan Vivo later requires a dated phylogeny, swap the distance matrix here only.

library(vegan)

#' @param matrix_by_group named list of named abundance vectors (one per group).
#' @param taxonomy data frame of taxonomic ranks (rownames = scientificName),
#'   from parse_taxonomy_tree().
#' @return list(deltaStar, deltaPlus)
pillar3_taxonomic_dissimilarity <- function(matrix_by_group, taxonomy) {
  all_species <- unique(unlist(lapply(matrix_by_group, names)))
  if (length(all_species) < 2 || nrow(taxonomy) < 2) {
    return(list(deltaStar = NA, deltaPlus = NA))
  }

  # Restrict the taxonomy to observed species, in a stable order.
  tax <- taxonomy[rownames(taxonomy) %in% all_species, , drop = FALSE]
  tax <- unique(tax)
  species_order <- rownames(tax)

  # Equal-step taxonomic distance matrix across ranks (vegan::taxa2dist).
  dis <- vegan::taxa2dist(tax, varstep = FALSE, check = FALSE)

  # Site abundance vector (counts summed across Target Groups), aligned to `dis`.
  site_counts <- setNames(numeric(length(species_order)), species_order)
  for (tg in names(matrix_by_group)) {
    vec <- matrix_by_group[[tg]]
    for (sp in names(vec)) {
      if (sp %in% species_order) site_counts[[sp]] <- site_counts[[sp]] + vec[[sp]]
    }
  }
  comm <- matrix(site_counts, nrow = 1, dimnames = list("site", species_order))

  td <- vegan::taxondive(comm, dis)

  list(
    deltaStar = round(as.numeric(td$Dstar[1]), 4),  # within-group dissimilarity
    deltaPlus = round(as.numeric(td$Dplus[1]), 4)   # between-group dissimilarity
  )
}
