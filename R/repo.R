# Checks a challenge repository: its config and the files the config names.
# Challenge repos run this in their own tests or CI; the engine never holds a
# challenge's files itself.

#' Check a challenge repository
#'
#' Runs [config_problems()] on the repository's config and checks that every
#' local file the config names exists: each group's `targets_script`,
#' `catalog_config$site_columns_file`, the GitHub registry
#' (`submissions$repos$registry`) when it is a local path, and the site
#' metadata when it is a local path rather than a URL.
#'
#' @param root The challenge repository's root folder.
#' @param config Path of its config file.
#' @return A tibble with columns `severity`, `key` and `message`, one row per
#'   problem (none when the repository is consistent).
#' @export
#' @examples
#' \dontrun{
#' check_challenge_repo(".")
#' }
check_challenge_repo <- function(root = ".",
                                 config = file.path(root, "challenge_configuration.yaml")) {
  cfg <- read_config(config, validate = FALSE)
  problems <- config_problems(cfg)

  files <- c(
    purrr::imap_chr(
      purrr::compact(purrr::map(cfg$target_groups, "targets_script")),
      function(path, group) paste0("target_groups$", group, "$targets_script=", path)
    ),
    if (!is.null(cfg$catalog_config$site_columns_file)) {
      paste0("catalog_config$site_columns_file=", cfg$catalog_config$site_columns_file)
    },
    if (is_local_path(cfg$submissions$repos$registry)) {
      paste0("submissions$repos$registry=", cfg$submissions$repos$registry)
    },
    if (is_local_path(cfg$sites$metadata_url)) {
      paste0("sites$metadata_url=", cfg$sites$metadata_url)
    }
  )
  for (entry in files) {
    key <- sub("=.*$", "", entry)
    path <- sub("^[^=]*=", "", entry)
    if (!file.exists(file.path(root, path))) {
      problems <- dplyr::bind_rows(problems, tibble::tibble(
        severity = "error", key = key, message = paste0("file not found: ", path)
      ))
    }
  }
  problems
}

# A setting that is a file path in the repository, not a URL or missing.
is_local_path <- function(x) {
  rlang::is_string(x) && !grepl("^[a-z]+://", x)
}
