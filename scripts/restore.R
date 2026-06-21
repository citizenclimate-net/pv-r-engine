# Restore R packages from renv.lock using Posit Public Package Manager (P3M)
# binaries on Linux, so small boxes don't have to compile from source. On an OS
# without P3M binaries (e.g. Debian) this transparently falls back to source.

codename <- tryCatch({
  os <- readLines("/etc/os-release", warn = FALSE)
  cn <- grep("^VERSION_CODENAME=", os, value = TRUE)
  cn <- gsub('VERSION_CODENAME=|"', "", cn)
  if (length(cn) == 0 || cn == "") "jammy" else cn
}, error = function(e) "jammy")

options(
  repos = c(CRAN = sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest", codename)),
  # P3M serves binaries only when the User-Agent advertises the platform.
  HTTPUserAgent = sprintf(
    "R/%s R (%s)", getRversion(),
    paste(getRversion(), R.version$platform, R.version$arch, R.version$os)
  )
)

cat(sprintf("Restoring packages via P3M for '%s'\n", codename))
if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv")
renv::restore(prompt = FALSE)
