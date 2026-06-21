# Pillar 2 — Species Diversity (Hill number q = 1), DAP Requirements §2.3.
#
# "Calculated using the Hill number (q=1) (Hill 1973), using the iNEXT function
#  from the iNEXT package in R. Calculated separately per Target Group and then
#  produce the summed results (Hsieh et al 2016)."
#
# Hill q=1 is in "effective species" units, which are additive across Target
# Groups (Methodology §1.5.2), so the site-level metric is the sum.

library(iNEXT)

#' @param matrix_by_group named list of named abundance vectors (one per group).
#' @return list(value, ci95, perTargetGroup)
pillar2_species_diversity <- function(matrix_by_group) {
  per_group <- list()
  site_value <- 0
  site_lcl <- 0
  site_ucl <- 0

  for (tg in names(matrix_by_group)) {
    est <- estimate_group_diversity(matrix_by_group[[tg]])
    per_group[[tg]] <- est$estimator
    site_value <- site_value + est$estimator
    site_lcl <- site_lcl + est$lcl
    site_ucl <- site_ucl + est$ucl
  }

  list(
    value = round(site_value, 2),
    ci95 = c(round(site_lcl, 2), round(site_ucl, 2)),
    perTargetGroup = per_group
  )
}

#' Asymptotic Hill q=1 (Shannon diversity, effective species) for one group.
estimate_group_diversity <- function(vec) {
  observed <- length(vec)
  if (sum(vec) < 3 || observed < 2) {
    return(list(estimator = observed, lcl = observed, ucl = observed))
  }
  res <- iNEXT::iNEXT(vec, q = 1, datatype = "abundance",
                      se = TRUE, conf = 0.95, nboot = 200)
  asy <- res$AsyEst
  row <- asy[asy$Diversity == "Shannon diversity", ][1, ]
  list(
    estimator = as.numeric(row$Estimator),
    lcl = as.numeric(row$LCL),
    ucl = as.numeric(row$UCL)
  )
}
