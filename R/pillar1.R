# Pillar 1 — Species Richness (Hill number q = 0), DAP Requirements §2.3.
#
# "Calculated using the Hill number (q=0) (Hill 1973) using the iNEXT function
#  from the iNEXT package in R (Hsieh et al 2016)."
#
# Richness is estimated for each Target Group individually (different groups use
# different data-collection tools and sampling effort), then the asymptotic
# estimators are summed for the site-level metric (Methodology §1.5.1).

library(iNEXT)

#' @param matrix_by_group named list of named abundance vectors (one per Target
#'   Group), as produced by parse_species_matrix().
#' @return list(value, ci95, perTargetGroup)
pillar1_species_richness <- function(matrix_by_group) {
  per_group <- list()
  site_estimator <- 0
  site_lcl <- 0
  site_ucl <- 0

  for (tg in names(matrix_by_group)) {
    vec <- matrix_by_group[[tg]]
    est <- estimate_group_richness(vec)
    per_group[[tg]] <- est$estimator
    site_estimator <- site_estimator + est$estimator
    site_lcl <- site_lcl + est$lcl
    site_ucl <- site_ucl + est$ucl
  }

  list(
    value = round(site_estimator, 2),
    ci95 = c(round(site_lcl, 2), round(site_ucl, 2)),
    perTargetGroup = per_group
  )
}

#' Asymptotic species richness (q = 0) for a single Target Group via iNEXT.
#' Falls back to observed richness when n < 3 (iNEXT cannot extrapolate).
estimate_group_richness <- function(vec) {
  observed <- length(vec)
  if (sum(vec) < 3 || observed < 2) {
    return(list(estimator = observed, lcl = observed, ucl = observed))
  }
  res <- iNEXT::iNEXT(vec, q = 0, datatype = "abundance",
                      se = TRUE, conf = 0.95, nboot = 200)
  asyest_row(res$AsyEst, "richness")
}

# Standalone reproducibility entry point: `Rscript R/pillar1.R input.csv`
# (CSV columns: targetGroup, scientificName, count).
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) >= 1) {
    source("R/matrix.R")
    df <- utils::read.csv(args[1], stringsAsFactors = FALSE)
    by_group <- split(df, df$targetGroup)
    mat <- lapply(by_group, function(g) { v <- g$count; names(v) <- g$scientificName; v })
    print(jsonlite::toJSON(pillar1_species_richness(mat), auto_unbox = TRUE, pretty = TRUE))
  }
}
