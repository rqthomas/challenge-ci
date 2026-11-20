# The MinIO client (mc), which every upload and most listings go through.
#
# minioclient::install_mc() downloads mc from https://dl.min.io/client/mc/release/,
# which now returns HTTP 410 Gone: MinIO withdrew the community downloads. So the
# engine takes the last published release from GitHub instead, checks it against
# a pinned SHA-256 and puts it where minioclient looks for it. The workflows'
# install-mc action does the same before a job starts; ensure_mc() lets a stage or
# script work without it, e.g. on a new machine.

mc_release <- "RELEASE.2025-08-13T08-35-41Z"

# SHA-256 of each supported build of `mc_release`, from the .sha256sum files
# published with the release.
mc_checksums <- function() {
  c(
    "linux-amd64" = "01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891",
    "linux-arm64" = "14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c",
    "darwin-amd64" = "2862c79cce11b09be9a8911a279b2e9465bebf74b9f01abca9c348a0d795f0cb",
    "darwin-arm64" = "a877fd0c183409da9f20f9d6e1811987298bbbca1aa03428eebdffba79fb9445"
  )
}

# "linux-amd64", "darwin-arm64", ...; NA on a system with no build here.
mc_platform <- function() {
  info <- Sys.info()
  os <- c(Linux = "linux", Darwin = "darwin")[info[["sysname"]]]
  cpu <- if (info[["machine"]] %in% c("arm64", "aarch64")) "arm64" else "amd64"
  paste(os, cpu, sep = "-")
}

# Where minioclient looks for the binary.
mc_path <- function() {
  dir <- getOption("minioclient.dir", tools::R_user_dir("minioclient", "data"))
  file.path(dir, "mc")
}

# Download `url` to `dest` (a separate function so tests can replace it).
download_mc_asset <- function(url, dest) {
  withr::local_options(timeout = max(600, getOption("timeout")))
  with_retry(utils::download.file(url, dest, mode = "wb", quiet = TRUE), times = 3, wait = 5)
  invisible(dest)
}

#' Make sure the MinIO client is installed
#'
#' Does nothing when the binary is already where [minioclient::mc_ls()] and the
#' like look for it. Otherwise downloads the pinned release from GitHub (not
#' from `dl.min.io`, which now answers `410 Gone`, so
#' `minioclient::install_mc()` fails), checks its SHA-256 and makes it
#' executable. Linux and macOS, on Intel or ARM, are supported; on another
#' system install `mc` by hand into the folder named in the error.
#'
#' Call it where the code used `minioclient::install_mc()`.
#'
#' @return The path of the binary, invisibly.
#' @export
#' @examples
#' \dontrun{
#' ensure_mc()
#' }
ensure_mc <- function() {
  path <- mc_path()
  if (file.exists(path)) return(invisible(path))

  platform <- mc_platform()
  expected <- unname(mc_checksums()[platform])
  if (is.na(expected)) {
    cli::cli_abort(c(
      "There is no mc build for {.val {platform}} to install.",
      "i" = "Install the MinIO client yourself as {.path {path}}."
    ))
  }

  log_step("Installing the MinIO client {mc_release} ({platform})")
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  url <- paste0("https://github.com/minio/mc/releases/download/", mc_release,
                "/mc.", platform, ".", mc_release)
  download_mc_asset(url, path)

  actual <- as.character(openssl::sha256(file(path)))
  if (!isTRUE(actual == expected)) {
    unlink(path)
    cli::cli_abort(c(
      "The downloaded mc does not match its pinned checksum, so it was removed.",
      "x" = "Expected {expected}, got {actual}."
    ))
  }
  Sys.chmod(path, "755")
  invisible(path)
}
