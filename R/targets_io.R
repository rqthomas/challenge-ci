# The shared last steps of every targets script: format_targets() puts the
# targets in the standard format, check_targets() compares them with the
# published file, and write_targets() uploads them.
#
# Downloading and cleaning the data stays in each challenge's targets/*.R
# scripts, because it is specific to the data source.

#' Where a target group's targets file is stored
#'
#' The group's `targets_file` setting is a public URL on the main store's
#' endpoint. This returns the same object as a remote path.
#'
#' @inheritParams group_config
#' @param alias Remote connection (alias) of the main store.
#' @return A remote path.
#' @export
targets_object <- function(cfg, group, alias = "main") {
  url <- group_config(cfg, group)$targets_file
  prefix <- paste0("https://", config_get(cfg, "endpoint"), "/")
  if (!rlang::is_string(url) || !startsWith(url, prefix)) {
    cli::cli_abort(
      "{.field target_groups${group}$targets_file} must be a URL starting {.url {prefix}}."
    )
  }
  paste0(alias, "/", substring(url, nchar(prefix) + 1))
}

#' The targets files to read
#'
#' Every target group's `targets_file`, once each. In a dry run, a file that
#' an earlier dry run wrote (with [write_targets()], into the same
#' `DRY_RUN_DIR`) is read from there instead of from the store. Later stages
#' can then be dry-run on targets that are not published yet, as when
#' launching a challenge.
#'
#' When the main store is private (`public_read: false`) a URL cannot be read
#' directly, so each file is downloaded with the store's key into a temporary
#' folder and its local path is returned instead.
#'
#' @inheritParams config_get
#' @param files Targets file URLs. Defaults to every group's.
#' @return A character vector of URLs or local paths.
#' @export
targets_files <- function(cfg, files = target_variables(cfg)$targets_file) {
  files <- unique(stats::na.omit(files))
  purrr::map_chr(files, function(url) {
    group <- targets_group(cfg, url)
    # A file outside the store (e.g. a local path) is read as it is.
    object <- tryCatch(targets_object(cfg, group), error = function(e) NULL)
    local <- if (!is.null(object) && is_dry_run()) file.path(dry_run_dir(), object)
    if (!is.null(local) && file.exists(local)) {
      cli::cli_inform("DRY RUN: reading {.path {local}} instead of {.url {url}}.")
      local
    } else if (!is.null(object) && !anonymous_reads(cfg)) {
      download_targets(cfg, object)
    } else {
      url
    }
  })
}

# The target group whose `targets_file` is `url`.
targets_group <- function(cfg, url) {
  urls <- purrr::map_chr(cfg$target_groups, \(g) g$targets_file %||% NA_character_)
  names(cfg$target_groups)[urls %in% url][1]
}

# Download a targets file from the private main store into a temporary folder.
download_targets <- function(cfg, object) {
  remote_connect(cfg, "main")
  dir <- file.path(tempdir(), "targets", gsub("[^A-Za-z0-9]+", "_", dirname(object)))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(dir, basename(object))
  remote_download(object, dest)
  dest
}

#' Put targets in the standard format
#'
#' @param targets A data frame with `site_id`, `datetime`, `variable` and
#'   `observation`.
#' @inheritParams config_get
#' @param duration ISO 8601 duration of the targets, e.g. `"P1D"`.
#' @return A tibble with columns `project_id`, `site_id`, `datetime` (POSIXct,
#'   UTC), `duration`, `variable` and `observation`, sorted, with `NaN`
#'   observations as `NA`.
#' @export
format_targets <- function(targets, cfg, duration) {
  missing <- setdiff(c("site_id", "datetime", "variable", "observation"), names(targets))
  if (length(missing) > 0) cli::cli_abort("Targets are missing column{?s} {.field {missing}}.")
  targets |>
    dplyr::transmute(
      project_id = cfg$project_id,
      site_id = as.character(.data$site_id),
      datetime = lubridate::as_datetime(.data$datetime),
      duration = duration,
      variable = as.character(.data$variable),
      observation = dplyr::if_else(is.nan(.data$observation), NA_real_,
                                   as.numeric(.data$observation))
    ) |>
    dplyr::arrange(.data$variable, .data$site_id, .data$datetime)
}

#' Read the targets file currently published for a group
#'
#' @inheritParams group_config
#' @return The targets as a tibble, or `NULL` when no file has been published
#'   yet. Read errors are raised, never taken to mean "no file".
#' @export
read_published_targets <- function(cfg, group) {
  url <- group_config(cfg, group)$targets_file
  remote_connect(cfg, "main", alias = "main_public", anonymous = anonymous_reads(cfg))
  object <- targets_object(cfg, group, alias = "main_public")
  if (!remote_exists(object)) return(NULL)
  # A private store's file cannot be fetched by its URL.
  path <- if (anonymous_reads(cfg)) url else download_targets(cfg, object)
  readr::read_csv(path, guess_max = 1e6, show_col_types = FALSE, progress = FALSE)
}

#' Check new targets before they replace the published ones
#'
#' Stops, so nothing is uploaded, when the new targets:
#' * lack a standard column or contain duplicate site/datetime/variable rows;
#' * hold variables the group does not have in the config;
#' * have fewer than `min_fraction` of the published file's rows; or
#' * have lost sites or variables the published file had.
#'
#' A failed or partial download usually shows up as one of the last two, so
#' this check stops a bad run from overwriting good targets.
#'
#' @param targets New targets from [format_targets()].
#' @inheritParams group_config
#' @param published The currently published targets, or `NULL` if there are
#'   none. Defaults to [read_published_targets()].
#' @param min_fraction Smallest allowed size of the new targets relative to the
#'   published ones.
#' @return `targets`, invisibly, if they pass.
#' @export
check_targets <- function(targets, cfg, group, published = read_published_targets(cfg, group),
                          min_fraction = 0.95) {
  problems <- character()
  standard <- c("project_id", "site_id", "datetime", "duration", "variable", "observation")
  if (!identical(names(targets), standard)) {
    problems <- c(problems, "columns are not the standard ones; use format_targets()")
  }
  n_dup <- sum(duplicated(targets[c("site_id", "datetime", "variable")]))
  if (n_dup > 0) problems <- c(problems, paste(n_dup, "duplicated site/datetime/variable rows"))

  config_vars <- dplyr::filter(target_variables(cfg), .data$group == !!group)$variable
  extra <- setdiff(unique(targets$variable), config_vars)
  if (length(extra) > 0) {
    problems <- c(problems, paste("variables not in the config:", toString(extra)))
  }

  if (!is.null(published) && nrow(published) > 0) {
    n_old <- nrow(published)
    n_new <- nrow(targets)
    log_step("{group} targets: {n_old} rows published, {n_new} new ",
             "({sprintf('%+.1f%%', 100 * (n_new - n_old) / n_old)}), ",
             "latest {max(targets$datetime, na.rm = TRUE)}")
    if (n_new < min_fraction * n_old) {
      problems <- c(problems, paste0(n_new, " rows, fewer than ", 100 * min_fraction,
                                     "% of the ", n_old, " published"))
    }
    lost_sites <- setdiff(unique(published$site_id), unique(targets$site_id))
    if (length(lost_sites) > 0) {
      problems <- c(problems, paste("sites missing:", toString(lost_sites)))
    }
    lost_vars <- setdiff(unique(published$variable), unique(targets$variable))
    if (length(lost_vars) > 0) {
      problems <- c(problems, paste("variables missing:", toString(lost_vars)))
    }
  }

  if (length(problems) > 0) {
    cli::cli_abort(c("{group} targets failed their checks; not uploading:",
                     rlang::set_names(problems, "x")))
  }
  invisible(targets)
}

#' Upload a group's targets
#'
#' Writes `<group's targets file name>` and uploads it to the location in the
#' group's `targets_file` setting, or to [dry_run_dir()] in a dry run.
#'
#' @param targets Targets that passed [check_targets()].
#' @inheritParams group_config
#' @return The destination written, invisibly.
#' @export
write_targets <- function(targets, cfg, group) {
  dest <- targets_object(cfg, group)
  file <- file.path(tempfile("targets"), basename(dest))
  dir.create(dirname(file))
  on.exit(unlink(dirname(file), recursive = TRUE))
  readr::write_csv(targets, file)
  if (!is_dry_run()) remote_connect(cfg, "main")
  upload_file(file, dest)
}
