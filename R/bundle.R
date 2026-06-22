# Audit-bundle builder: assembles the reproducibility .zip for a metric run and
# returns it base64-encoded together with provenance hashes. The Cloud Function
# uploads the bytes to Firebase Storage, so this R service needs no Firebase
# credentials at runtime. Bundle layout (DAP Requirements §2.1 transparency):
#
#   audit_bundle_{runId}.zip
#   ├── README.md
#   ├── inputs/   species_count_matrix.csv, taxonomy_tree.csv, input_snapshot.sha256
#   ├── code/     api.R, matrix.R, pillar1-3.R, renv.lock
#   ├── outputs/  pillar_metrics.json
#   └── provenance/ run_metadata.json, host_fingerprint.txt,
#                   renv_lock_sha256.txt, code_commit_sha.txt

library(jsonlite)

# Run a shell command, returning trimmed first line of stdout or NA on failure.
.sys <- function(cmd, args) {
  out <- tryCatch(system2(cmd, args, stdout = TRUE, stderr = FALSE),
                  error = function(e) NA_character_, warning = function(w) NA_character_)
  if (length(out) == 0 || all(is.na(out))) return(NA_character_)
  trimws(out[1])
}

#' Build the audit bundle for a run.
#' @return list(zipBase64, renvLockSha256, codeCommitSha, hostFingerprint, sizeBytes)
build_audit_bundle <- function(run_id, matrix_by_group, taxonomy, pillars_out, meta) {
  code_dir <- "/srv/cc-pv-r"
  base <- file.path("/var/lib/cc-pv-r/runs", run_id)
  unlink(base, recursive = TRUE)
  for (d in c("inputs", "code", "outputs", "provenance")) {
    dir.create(file.path(base, d), recursive = TRUE, showWarnings = FALSE)
  }

  # ── inputs ────────────────────────────────────────────────────────────────
  rows <- list()
  for (tg in names(matrix_by_group)) {
    v <- matrix_by_group[[tg]]
    for (sp in names(v)) {
      rows[[length(rows) + 1]] <- data.frame(
        targetGroup = tg, scientificName = sp, count = as.numeric(v[[sp]]),
        stringsAsFactors = FALSE)
    }
  }
  mat_df <- if (length(rows)) do.call(rbind, rows) else
    data.frame(targetGroup = character(), scientificName = character(), count = numeric())
  utils::write.csv(mat_df, file.path(base, "inputs", "species_count_matrix.csv"), row.names = FALSE)

  if (!is.null(taxonomy) && nrow(taxonomy) > 0) {
    tax_out <- cbind(scientificName = rownames(taxonomy), taxonomy)
    utils::write.csv(tax_out, file.path(base, "inputs", "taxonomy_tree.csv"), row.names = FALSE)
  }
  writeLines(as.character(meta$inputSnapshotSha256 %||% ""),
             file.path(base, "inputs", "input_snapshot.sha256"))

  # ── code (the exact scripts that ran) ──────────────────────────────────────
  for (f in c("api.R", "renv.lock")) {
    src <- file.path(code_dir, f)
    if (file.exists(src)) file.copy(src, file.path(base, "code", f), overwrite = TRUE)
  }
  for (f in list.files(file.path(code_dir, "R"), full.names = TRUE)) {
    file.copy(f, file.path(base, "code", basename(f)), overwrite = TRUE)
  }

  # ── outputs ────────────────────────────────────────────────────────────────
  writeLines(jsonlite::toJSON(pillars_out, auto_unbox = TRUE, pretty = TRUE, na = "null"),
             file.path(base, "outputs", "pillar_metrics.json"))

  # ── provenance ─────────────────────────────────────────────────────────────
  renv_sha <- .sys("sha256sum", file.path(code_dir, "renv.lock"))
  if (!is.na(renv_sha)) renv_sha <- sub("\\s.*$", "", renv_sha)
  commit <- .sys("git", c("-C", code_dir, "rev-parse", "HEAD"))
  host <- Sys.getenv("PV_HOST_FINGERPRINT", unset = Sys.info()[["nodename"]])

  writeLines(as.character(host %||% ""), file.path(base, "provenance", "host_fingerprint.txt"))
  writeLines(as.character(renv_sha %||% ""), file.path(base, "provenance", "renv_lock_sha256.txt"))
  writeLines(as.character(commit %||% ""), file.path(base, "provenance", "code_commit_sha.txt"))
  run_meta <- list(
    runId = run_id, rVersion = R.version.string,
    packageVersions = pv_package_versions(), hostFingerprint = host,
    codeCommitSha = commit, renvLockSha256 = renv_sha,
    computedAt = meta$computedAt %||% NA, year = meta$year %||% NA)
  writeLines(jsonlite::toJSON(run_meta, auto_unbox = TRUE, pretty = TRUE, na = "null"),
             file.path(base, "provenance", "run_metadata.json"))

  # ── README ─────────────────────────────────────────────────────────────────
  writeLines(c(
    "# PV Nature Pillar Metrics — Audit Bundle",
    "",
    sprintf("Run: %s", run_id),
    sprintf("Monitoring year: %s", meta$year %||% ""),
    sprintf("Computed: %s", meta$computedAt %||% ""),
    sprintf("R: %s", R.version.string),
    "",
    "## Reproduce",
    "```",
    sprintf("git clone https://github.com/citizenclimate-net/pv-r-engine"),
    sprintf("cd pv-r-engine && git checkout %s", commit %||% "<commit>"),
    "Rscript -e \"renv::restore(prompt=FALSE)\"",
    "Rscript R/pillar1.R inputs/species_count_matrix.csv",
    "```",
    "",
    "Input SHA-256, R + package versions are pinned in provenance/run_metadata.json."
  ), file.path(base, "README.md"))

  # ── zip + base64 ───────────────────────────────────────────────────────────
  zip_path <- file.path("/var/lib/cc-pv-r/runs", paste0(run_id, ".zip"))
  unlink(zip_path)
  old <- getwd(); setwd(base); on.exit(setwd(old), add = TRUE)
  utils::zip(zipfile = zip_path, files = ".", flags = "-r9Xq")
  setwd(old)

  raw <- readBin(zip_path, "raw", n = file.info(zip_path)$size)
  list(
    zipBase64 = jsonlite::base64_enc(raw),
    renvLockSha256 = if (is.na(renv_sha)) NULL else renv_sha,
    codeCommitSha = if (is.na(commit)) NULL else commit,
    hostFingerprint = host,
    sizeBytes = length(raw)
  )
}
