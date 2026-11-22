# Processing new submissions: download from the submissions bucket and from
# contributors' git repositories (see repo_submissions.R); check, filter to the
# challenge's own rows, standardise, and write to the forecasts bucket as
# parquet plus summaries. Both sources share one processed-submissions record
# and one record of the forecast units already stored.
#
# Since 2026-09-08 the NRP submissions key has had ListBucket permission only:
# GetObject and DeleteObject return "Insufficient permissions". The bucket's
# own policy grants GetObject-by-ACL and DeleteObject to everyone, so an
# anonymous client can read and delete but cannot list. We therefore list with
# the authenticated alias and read and delete through an anonymous one. Because
# deleting may fail, we also keep our own record (the "manifest") of every
# submission handled, on the main store, and skip those keys. Drop the
# anonymous alias once NRP restores the key's permissions. Operators: see
# "The submissions bucket workaround" in docs/operations.md.

# The file-name themes of the challenge's target groups.
challenge_themes <- function(cfg) {
  unname(purrr::imap_chr(cfg$target_groups, \(g, group) g$theme %||% tolower(group)))
}

# Remote connections (aliases) used for the submissions bucket.
submissions_alias <- "submissions"
submissions_public_alias <- "submissions_public"

# Files handled between two writes of the record.
record_batch_size <- 25L

# The record -----------------------------------------------------------------

empty_record <- function() {
  tibble::tibble(key = character(), sha = character(), status = character())
}

#' Read the record of processed submissions
#'
#' A CSV with a row for each file the CI has handled: its `key`, the file's
#' `sha` (a git blob SHA for repositories) and the `status` it ended with. A
#' file with only a `key` column (the first version of the record) counts as
#' processed.
#'
#' Only a record that does not exist yet starts a new, empty one. Any other
#' error (access, network) stops the run, because carrying on with an empty
#' record would overwrite the real one and reprocess every submission.
#'
#' @inheritParams config_get
#' @return A tibble with `key`, `sha` and `status`.
#' @export
read_manifest <- function(cfg) {
  remote <- bucket_uri(cfg, "processed_submissions", scheme = "remote")
  if (!remote_exists(remote)) {
    cli::cli_inform("No processed-submissions record found; starting a new one.")
    return(empty_record())
  }
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  remote_download(remote, local)
  manifest <- readr::read_csv(local, col_types = readr::cols(.default = "c"), progress = FALSE)
  if (!"key" %in% names(manifest)) {
    cli::cli_abort("Processed-submissions record {.path {remote}} has no {.field key} column.")
  }
  for (col in setdiff(c("sha", "status"), names(manifest))) manifest[[col]] <- NA_character_
  manifest$status <- dplyr::coalesce(manifest$status, "processed")
  manifest[, c("key", "sha", "status")]
}

#' @rdname read_manifest
#' @param record The record to write: a tibble with `key`, `sha` and `status`.
#' @export
write_manifest <- function(cfg, record) {
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  readr::write_csv(record[, c("key", "sha", "status")], local)
  upload_file(local, bucket_uri(cfg, "processed_submissions", scheme = "remote"))
}

#' What the record stops from being looked at again
#'
#' A file that was processed or found invalid is not looked at again, whatever
#' happens to it later (the first version of a path wins). A file that was
#' `skipped` because nothing in it belongs to this challenge is looked at again
#' if it is edited, so its token is the key plus the file's SHA. The bucket
#' has no SHA before download, so its skipped files are held by key.
#'
#' @param record From [read_manifest()].
#' @return A character vector of tokens: `key`, or `key@sha`.
#' @export
manifest_tokens <- function(record) {
  by_sha <- record$status %in% "skipped" & !is.na(record$sha)
  # (paste0() of empty vectors is "@", not nothing.)
  held_by_sha <- character()
  if (any(by_sha)) held_by_sha <- paste0(record$key[by_sha], "@", record$sha[by_sha])
  unique(c(record$key[!by_sha], held_by_sha))
}

record_add <- function(state, key, sha, status) {
  state$record <- dplyr::bind_rows(
    state$record[state$record$key != key, ],
    tibble::tibble(key = key, sha = sha, status = status)
  )
}

# The forecast units already stored -------------------------------------------

# A unit is one model's forecast for one variable and duration issued on one
# reference date. A file holds many; the first rows stored for a unit win.
# The record is a CSV next to the processed-submissions record, read once per
# run into a set, so checking a file's units costs no remote calls.

units_remote <- function(cfg) {
  remote <- bucket_uri(cfg, "processed_submissions", scheme = "remote")
  if (endsWith(remote, ".csv")) {
    sub("\\.csv$", "_units.csv", remote)
  } else {
    paste0(remote, "_units.csv")
  }
}

new_units <- function(keys = character()) {
  units <- new.env()
  units$set <- new.env(hash = TRUE, parent = emptyenv())
  units$dirty <- FALSE
  for (key in unique(keys)) assign(key, TRUE, envir = units$set)
  units
}

unit_keys <- function(model_id, reference_date, variable, duration) {
  paste(model_id, as.character(reference_date), variable, duration, sep = "\t")
}

units_has <- function(units, keys) {
  vapply(keys, exists, logical(1), envir = units$set, inherits = FALSE, USE.NAMES = FALSE)
}

units_add <- function(units, keys) {
  for (key in unique(keys)) assign(key, TRUE, envir = units$set)
  units$dirty <- TRUE
  invisible(units)
}

#' Read the record of forecast units already stored
#'
#' One row per (model, reference date, variable, duration) stored, in a CSV next
#' to the processed-submissions record. It lets the submissions stage keep the
#' first forecast for each unit without asking the forecast store about every
#' variable and date in every file. A missing file is an empty record; if it is
#' lost, rebuild it with [rebuild_unit_record()].
#'
#' @inheritParams config_get
#' @return An environment used by the submissions stage.
#' @export
read_units <- function(cfg) {
  remote <- units_remote(cfg)
  if (!remote_exists(remote)) return(new_units())
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  remote_download(remote, local)
  rows <- readr::read_csv(local, col_types = readr::cols(.default = "c"), progress = FALSE)
  new_units(unit_keys(rows$model_id, rows$reference_date, rows$variable, rows$duration))
}

write_units <- function(cfg, units) {
  keys <- ls(units$set, all.names = TRUE)
  parts <- strsplit(keys, "\t", fixed = TRUE)
  rows <- tibble::tibble(
    model_id = vapply(parts, `[`, character(1), 1),
    reference_date = vapply(parts, `[`, character(1), 2),
    variable = vapply(parts, `[`, character(1), 3),
    duration = vapply(parts, `[`, character(1), 4)
  )
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  readr::write_csv(rows, local)
  upload_file(local, units_remote(cfg))
}

#' Rebuild the record of forecast units from the stored summaries
#'
#' Scans the summaries bucket once and writes the units found to a local CSV.
#' Upload it to the place named in the log (next to the processed-submissions
#' record) to restore a lost record. Reads only; never writes to the stores.
#'
#' @inheritParams config_get
#' @param path Local CSV to write.
#' @return `path`, invisibly.
#' @export
rebuild_unit_record <- function(cfg, path = "processed_submissions_units.csv") {
  summaries <- bucket_uri(cfg, "summaries_bucket", "summaries")
  conn <- duckdbfs::cached_connection()
  rows <- duckdbfs::open_dataset(file.path(summaries, "**"), format = "parquet",
                                 hive_style = TRUE, conn = conn) |>
    dplyr::filter(.data$project_id == !!cfg$project_id) |>
    dplyr::distinct(.data$model_id, .data$reference_date, .data$variable, .data$duration) |>
    dplyr::collect()
  readr::write_csv(rows, path)
  cli::cli_inform(
    "Wrote {nrow(rows)} unit{?s} to {.path {path}}; upload it to {.path {units_remote(cfg)}}."
  )
  invisible(path)
}

# Planning -------------------------------------------------------------------

#' Decide which submissions to download
#'
#' @param keys Every key in the submissions bucket.
#' @param processed Tokens of the processed-submissions record (see
#'   [manifest_tokens()]).
#' @param exclude_patterns Regular expressions. Keys matching any of them are
#'   never downloaded or recorded (`submissions$exclude_patterns` in the
#'   config).
#' @param themes If given, only keys whose file name starts with one of these
#'   themes (`<theme>-<date>-<model_id>`) are downloaded; all others are left
#'   alone like excluded ones. Set from the target groups' themes when the
#'   config has `submissions$known_themes_only: true`, so that challenges can
#'   share a submissions bucket.
#' @return A list with `download` (new keys), `stale` (processed keys still in
#'   the bucket, to delete) and `n_excluded`.
#' @export
#' @examples
#' plan_submissions(c("a.csv", "b.csv", "old-2023.csv"), processed = "a.csv",
#'                  exclude_patterns = "2023")
#' plan_submissions(c("lakes-2026-01-01-m.csv", "aquatics-2026-01-01-m.csv"),
#'                  processed = character(), themes = "lakes")
plan_submissions <- function(keys, processed, exclude_patterns = character(),
                             themes = NULL) {
  excluded <- rep(FALSE, length(keys))
  for (pattern in exclude_patterns) excluded <- excluded | grepl(pattern, keys)
  if (!is.null(themes)) {
    excluded <- excluded | !parse_submission_filename(keys)$theme %in% themes
  }
  wanted <- keys[!excluded]
  list(
    download = setdiff(wanted, processed),
    stale = intersect(keys, processed),
    n_excluded = sum(excluded)
  )
}

#' Decide which bucket files belong to a registered model
#'
#' Every model has a repository with a `challenge-model.yaml`, and the registry
#' says whether its forecasts go to a `repo` or the `bucket`. A bucket file is
#' processed when its model id (from the file name, so no download is needed) is
#' registered for the bucket, or is one of the challenge's own baselines. A model
#' registered for a repository is skipped: its forecasts must come from there.
#' A model that is not registered at all is processed with a note to register
#' until `strict`, and skipped after.
#'
#' @param keys Bucket keys.
#' @param models Registered models with `model_id`, `location` and `repo`, from
#'   [load_registry()]. `NULL` when the challenge has no registry; every file is
#'   then processed.
#' @param baseline_ids The challenge's own baseline model ids.
#' @param strict Skip models that are not registered.
#' @return A tibble with `key`, `model_id`, `action` (`"process"` or `"skip"`),
#'   `reason`, `registered` and `note` (a warning to publish, for a model that
#'   should register).
#' @export
plan_bucket_ownership <- function(keys, models, baseline_ids = character(), strict = FALSE) {
  model_id <- parse_submission_filename(keys)$model_id
  out <- tibble::tibble(key = keys, model_id = model_id, action = rep("process", length(keys)),
                        reason = NA_character_, registered = NA, note = NA_character_)
  if (is.null(models) || length(keys) == 0) return(out)

  location <- models$location[match(model_id, models$model_id)]
  repo <- models$repo[match(model_id, models$model_id)]
  baseline <- model_id %in% baseline_ids
  # A file whose name does not parse is left to process_submission(), which says so.
  known_name <- !is.na(model_id)

  in_repo <- known_name & !baseline & location %in% "repo"
  out$action[in_repo] <- "skip"
  out$reason[in_repo] <- paste0("model_id ", model_id[in_repo], " is registered to submit from ",
                                repo[in_repo], ", not the bucket")

  out$registered[known_name] <- baseline[known_name] | !is.na(location[known_name])

  unregistered <- known_name & !baseline & is.na(location)
  message <- paste0("model_id ", model_id, " is not registered: add a repository with a ",
                    challenge_model_file, " to the challenge's registry")
  if (strict) {
    out$action[unregistered] <- "skip"
    out$reason[unregistered] <- message[unregistered]
  } else {
    out$note[unregistered] <- message[unregistered]
  }
  out
}

# Old-format bucket files are accepted (and unregistered models processed)
# until `submissions$bucket$strict_from`; with no date they always are.
bucket_is_strict <- function(cfg, today = Sys.Date()) {
  strict_from <- cfg$submissions$bucket$strict_from
  !is.null(strict_from) && today >= as.Date(as.character(strict_from))
}

# Processing one file -----------------------------------------------------------

#' Process one downloaded submission
#'
#' Checks the file, then reads, validates, filters to this challenge's rows and
#' standardises the forecast. For a valid forecast with rows left, writes parquet
#' and summaries under `out_dir` (in `parquet/` and `summaries/`) ready to
#' upload.
#'
#' `context` says where the file came from:
#' * `route`: `"bucket"` (the file name must be `<theme>-<date>-<model_id>`, and
#'   a `model_id` column must agree with it) or `"repo"` (the name is free; the
#'   forecast is identified by its columns);
#' * `name`: the file's name or key (default: the file name of `path`);
#' * `allowed`: the model ids the file may hold (default: any);
#' * `legacy`: accept the old format, see [validate_forecast()];
#' * `max_bytes`: the largest file accepted;
#' * `rules`: from [submission_rules()] (default: read from `cfg`);
#' * `units`: the stored units, see [read_units()]; rows of a unit already
#'   stored are dropped (default: no check).
#'
#' @param path Local path of the downloaded file.
#' @inheritParams config_get
#' @param out_dir Local folder for the output.
#' @param pub_datetime Publication time stamped on the forecast.
#' @param context A list, see above.
#' @return A list with `status` and `reason`, and `warnings` (the validation
#'   warnings, joined), `model_id`, `rows_kept`, `rows_dropped` and `units` (the
#'   units written) when the file was read. `status` is `"processed"`, or
#'   `"invalid"` (failed validation) or `"skipped"` (a file name, type or date
#'   that is not processed, or nothing in the file to store). Errors are raised,
#'   not returned, so a failure can be retried on the next run.
#' @export
process_submission <- function(path, cfg, out_dir, pub_datetime = Sys.time(),
                               context = list()) {
  route <- context$route %||% "bucket"
  name <- context$name %||% basename(path)
  legacy <- isTRUE(context$legacy)
  skipped <- function(reason, ...) list(status = "skipped", reason = reason, ...)
  invalid <- function(reason, warnings = "") {
    list(status = "invalid", reason = reason, warnings = warnings)
  }

  max_bytes <- context$max_bytes %||% Inf
  if (file.size(path) > max_bytes) {
    return(invalid(paste0("file is larger than ", round(max_bytes / 1e6), " MB")))
  }
  if (is_lfs_pointer(path)) {
    return(invalid("the file is a Git LFS pointer, not the forecast; commit the file itself"))
  }

  info <- parse_submission_filename(name)
  if (!grepl("\\.csv(\\.gz)?$", name)) {
    extension <- sub("^[^.]*\\.", "", basename(name))
    return(skipped(paste0(".", extension, " files are not accepted")))
  }
  if (route == "bucket") {
    if (is.na(info$model_id)) {
      return(skipped("name is not <theme>-<YYYY-MM-DD>-<model_id>.<ext>"))
    }
    min_date <- config_get(cfg, "submissions", "min_reference_date", default = NA)
    if (!is.na(min_date) && as.Date(info$reference_datetime) < as.Date(min_date)) {
      return(skipped(paste("reference date before", min_date)))
    }
  }

  fc <- read_submission(path)
  problems <- validate_forecast(fc, cfg, legacy = legacy)
  for (i in seq_len(nrow(problems))) {
    cli::cli_inform(c("!" = "{problems$severity[i]}: {problems$message[i]}"))
  }
  warned <- problems$message[problems$severity == "warning"]
  if (any(problems$severity == "error")) {
    return(invalid(paste(problems$message[problems$severity == "error"], collapse = "; "),
                   paste(warned, collapse = "; ")))
  }

  if (legacy) fc <- fill_legacy_columns(fc, cfg, info)
  model_id <- as.character(fc$model_id[1])
  if (route == "bucket" && !is.na(info$model_id) && !identical(model_id, info$model_id)) {
    return(invalid(paste0("the model_id in the file (", model_id,
                          ") is not the one in the file name (", info$model_id, ")"),
                   paste(warned, collapse = "; ")))
  }
  if (!is.null(context$allowed) && !model_id %in% context$allowed) {
    return(invalid(paste0("model_id ", model_id, " is not listed for this folder in ",
                          challenge_model_file), paste(warned, collapse = "; ")))
  }

  n_rows <- nrow(fc)
  none <- function(reason) {
    skipped(reason, model_id = model_id, rows_kept = 0L, rows_dropped = n_rows)
  }
  filtered <- filter_forecast_rows(fc, cfg, context$rules %||% submission_rules(cfg))
  notes <- c(warned, if (nrow(filtered$dropped) > 0) describe_dropped(filtered$dropped))
  if (nrow(filtered$forecast) == 0) {
    return(none(paste0("no rows for this challenge (", describe_dropped(filtered$dropped), ")")))
  }

  fc <- standardize_forecast(filtered$forecast, cfg, pub_datetime = pub_datetime)
  if (nrow(fc) == 0) {
    return(none(paste("no rows left after dropping rows before the reference date",
                      "or beyond the maximum horizon")))
  }

  fc$.unit <- unit_keys(fc$model_id, fc$reference_date, fc$variable, fc$duration)
  if (!is.null(context$units)) {
    units <- unique(fc$.unit)
    stored <- units[units_has(context$units, units)]
    if (length(stored) > 0) {
      notes <- c(notes, paste0(length(stored), " unit", if (length(stored) > 1) "s",
                               " already stored (model, reference date, variable, duration), ",
                               "dropped"))
      fc <- fc[!fc$.unit %in% stored, ]
    }
    if (nrow(fc) == 0) {
      return(none(paste("all", length(units), "unit(s) in the file were stored already")))
    }
  }
  new_units <- unique(fc$.unit)
  fc$.unit <- NULL

  file_id <- paste0("sub_", unname(tools::md5sum(path)))
  write_forecast_parquet(fc, file.path(out_dir, "parquet"), file_id)
  write_forecast_parquet(summarize_submission(fc), file.path(out_dir, "summaries"), file_id)
  list(status = "processed", reason = paste(nrow(fc), "rows"),
       warnings = paste(notes, collapse = "; "), model_id = model_id,
       rows_kept = nrow(fc), rows_dropped = n_rows - nrow(fc), units = new_units)
}

# Process a downloaded file and put everything it produces in its place:
# parquet and summaries (when valid) and the raw archive copy. Returns the
# outcome of process_submission(). Errors propagate, so the caller can leave the
# file out of the record and retry it. The file's units are remembered only once
# its output is uploaded.
store_submission <- function(cfg, local, key, out_dir, time_stamp, context = list()) {
  outcome <- process_submission(local, cfg, out_dir, context = context)
  if (outcome$status == "processed") {
    upload_dir(file.path(out_dir, "parquet"),
               bucket_uri(cfg, "forecasts_bucket", "parquet", scheme = "remote"))
    upload_dir(file.path(out_dir, "summaries"),
               bucket_uri(cfg, "summaries_bucket", "summaries", scheme = "remote"))
    if (!is.null(context$units)) units_add(context$units, outcome$units)
  }
  # A file over the size limit is reported but not archived.
  if (file.size(local) <= (context$max_bytes %||% Inf)) {
    upload_file(local, bucket_uri(cfg, "forecasts_bucket", "raw",
                                  paste0("T", time_stamp, "_", gsub("/", "_", key)),
                                  scheme = "remote"))
  }
  outcome
}

# Writing the record -----------------------------------------------------------

# Write the record (and the units, first: a unit remembered without its file in
# the record only costs a skipped repeat, the reverse would store duplicates),
# then delete the bucket files queued for deletion. Deleting only after the
# record is written means a failed write cannot lose a submission.
flush_state <- function(cfg, state) {
  if (state$pending > 0L) {
    if (state$units$dirty) {
      write_units(cfg, state$units)
      state$units$dirty <- FALSE
    }
    write_manifest(cfg, state$record)
    state$pending <- 0L
  }
  if (length(state$delete_queue) > 0 && is.function(state$remove)) {
    for (key in state$delete_queue) {
      state$n_removed <- state$n_removed + state$remove(key)
    }
  }
  state$delete_queue <- character()
  invisible(NULL)
}

# Download and process one file. `fetch(local)` downloads it (errors mean
# "unreadable"). Returns the results row and updates the record in `state`.
handle_submission <- function(cfg, state, key, source, sha, model_id, fetch, context,
                              results_name = model_id, file = key, record_sha = !is.na(sha),
                              delete_after = FALSE, note = NA_character_) {
  log_step("{key}")
  local <- file.path(state$work_dir, "raw", gsub("/", "_", key))
  dir.create(dirname(local), recursive = TRUE, showWarnings = FALSE)
  out_dir <- tempfile("out", tmpdir = state$work_dir)
  on.exit(unlink(c(local, out_dir), recursive = TRUE), add = TRUE)
  context$units <- state$units
  context$rules <- state$rules

  downloaded <- tryCatch({
    fetch(local)
    TRUE
  }, error = function(e) {
    cli::cli_warn("Could not download {.path {key}}: {conditionMessage(e)}")
    FALSE
  })
  if (!downloaded) {
    return(results_row(key, model_id, source, sha, "unreadable", "download failed",
                       results_name = results_name, file = file))
  }
  if (is.na(sha)) sha <- unname(tools::md5sum(local))

  result <- tryCatch(
    store_submission(cfg, local, key, out_dir, state$time_stamp, context),
    error = function(e) list(status = "failed", reason = conditionMessage(e))
  )
  if (result$status != "failed") {
    record_add(state, key, if (record_sha) sha else NA_character_, result$status)
    state$pending <- state$pending + 1L
    if (delete_after) state$delete_queue <- c(state$delete_queue, key)
    if (state$pending >= record_batch_size) flush_state(cfg, state)
  }
  if (result$status %in% c("invalid", "skipped", "failed")) {
    cli::cli_inform(c("!" = "{result$status}: {result$reason}"))
  }
  warnings <- paste(c(result$warnings[nzchar(result$warnings %||% "")], note[!is.na(note)]),
                    collapse = "; ")
  if (!is.null(result$model_id)) {
    model_id <- result$model_id
    results_name <- model_id
  }
  results_row(key, model_id, source, sha, result$status, result$reason, warnings,
              results_name = results_name, file = file,
              rows_kept = result$rows_kept %||% NA_integer_,
              rows_dropped = result$rows_dropped %||% NA_integer_)
}

# The stage ----------------------------------------------------------------------

#' Process all new submissions
#'
#' The `submissions` stage. New files come from up to two sources, used
#' together:
#'
#' * the submissions bucket (unless `submissions$use_bucket` is `false`): for
#'   models registered with `location: bucket`, and, until
#'   `submissions$bucket$strict_from`, models not registered at all;
#' * the contributors' git repositories listed in the registry named by
#'   `submissions$repos$registry`, when that is set (see
#'   [list_repo_submissions()]).
#'
#' For each new file:
#'
#' 1. download it (a file that cannot be read is skipped and retried next run);
#' 2. [process_submission()] it: keep the rows that belong to this challenge
#'    and drop those of a unit (model, reference date, variable, duration)
#'    already stored, then upload parquet and summaries to the forecasts and
#'    summaries buckets;
#' 3. archive the raw file in `<forecasts_bucket>/raw/`, valid or not;
#' 4. add it to the processed-submissions record and, for the bucket, delete it
#'    there (best effort) once the record is written.
#'
#' The record is written every few files and at the end, not after each file.
#' Afterwards what happened to each file is published for its submitter, see
#' [write_submission_results()].
#'
#' A submission that errors is logged and left out of the record, so it is
#' retried on the next run. The run carries on with the others, and with the
#' other source if one fails, and fails at the end if anything errored.
#'
#' @inheritParams config_get
#' @return A tibble with one row per file looked at: `key`, `status`
#'   (`"processed"`, `"invalid"`, `"skipped"`, `"unreadable"` or `"failed"`)
#'   and `reason`, with the columns described in [write_submission_results()],
#'   invisibly.
#' @export
run_submissions <- function(cfg) {
  log_step("Processing submissions")
  # A dry run without the main store's key reads its public buckets anonymously.
  remote_connect(cfg, "main", anonymous = is_dry_run() && read_anonymously_without_key(cfg))

  use_bucket <- isTRUE(config_get(cfg, "submissions", "use_bucket", default = TRUE))
  use_repos <- repos_enabled(cfg)
  if (!use_bucket && !use_repos) {
    cli::cli_abort(paste("No submission source is on: set {.field submissions$repos$registry}",
                         "or leave {.field submissions$use_bucket} true."))
  }

  state <- new.env()
  state$record <- read_manifest(cfg)
  state$units <- read_units(cfg)
  state$work_dir <- tempfile("submissions")
  state$time_stamp <- format(Sys.time(), "%Y%m%d%H%M%S")
  state$pending <- 0L
  state$delete_queue <- character()
  state$remove <- NULL
  state$n_removed <- 0L
  state$rules <- submission_rules(cfg)
  state$registry <- NULL
  on.exit(unlink(state$work_dir, recursive = TRUE), add = TRUE)

  source_errors <- character()
  if (use_repos) {
    log_step("Reading the repository registry")
    state$registry <- tryCatch(load_registry(cfg), error = function(e) {
      source_errors <<- c(source_errors, paste0("registry: ", conditionMessage(e)))
      NULL
    })
    on.exit(if (!is.null(state$registry)) close_registry(state$registry), add = TRUE)
  }

  results <- list()
  run_source <- function(name, fun) {
    log_step("Source: {name}")
    out <- tryCatch(
      {
        res <- fun(cfg, state)
        flush_state(cfg, state)
        res
      },
      error = function(e) {
        cli::cli_alert_danger("Source {name} failed: {conditionMessage(e)}")
        source_errors <<- c(source_errors, paste0(name, ": ", conditionMessage(e)))
        # Keep what the failed source did get done.
        tryCatch(flush_state(cfg, state), error = function(e2) {
          cli::cli_warn("Could not write the record: {conditionMessage(e2)}")
        })
        NULL
      }
    )
    if (!is.null(out)) results[[name]] <<- out
  }
  if (use_bucket) run_source("bucket", process_bucket_submissions)
  if (use_repos && !is.null(state$registry)) run_source("repos", process_repo_submissions)

  results <- dplyr::bind_rows(c(unname(results), list(state$registry$registrations)))
  if (nrow(results) == 0) results <- empty_results()
  counts <- table(factor(results$status,
                         c("processed", "invalid", "skipped", "unreadable", "failed")))
  log_step(
    "Done: {counts[['processed']]} processed, {counts[['invalid']]} invalid, ",
    "{counts[['skipped']]} skipped, {counts[['unreadable']]} unreadable, ",
    "{counts[['failed']]} failed."
  )

  write_submission_results(cfg, results)

  failed <- results$key[results$status == "failed" & !is.na(results$key)]
  if (length(source_errors) > 0) {
    cli::cli_abort(c("A submission source failed:", rlang::set_names(source_errors, "x")))
  }
  if (length(failed) > 0) {
    cli::cli_abort(c(
      "{length(failed)} submission{?s} failed and will be retried next run:",
      rlang::set_names(failed, "x")
    ))
  }
  invisible(results)
}

# The submissions bucket: list with the key, read and delete anonymously (see
# the note at the top of this file). Returns the results rows.
process_bucket_submissions <- function(cfg, state) {
  remote_connect(cfg, "submissions", alias = submissions_alias)
  remote_connect(cfg, "submissions", alias = submissions_public_alias, anonymous = TRUE)

  # With a registry, who may submit through the bucket is decided by it; if it
  # could not be read, nothing can be decided, so the bucket waits.
  if (repos_enabled(cfg) && is.null(state$registry)) {
    cli::cli_abort("The repository registry could not be read, so bucket files cannot be checked.")
  }

  bucket <- config_get(cfg, "submissions_bucket")
  public_key <- function(key) paste0(submissions_public_alias, "/", bucket, "/", key)
  state$remove <- function(key) {
    tryCatch(
      {
        remove_remote(public_key(key))
        1L
      },
      error = function(e) {
        cli::cli_warn(
          "Could not delete {.path {key}} from the submissions bucket: {conditionMessage(e)}"
        )
        0L
      }
    )
  }
  delete <- isTRUE(config_get(cfg, "submissions", "bucket", "delete_processed", default = TRUE))

  keys <- remote_files(paste0(submissions_alias, "/", bucket))$key
  plan <- plan_submissions(
    keys, manifest_tokens(state$record),
    exclude_patterns = unlist(config_get(cfg, "submissions", "exclude_patterns",
                                         default = character())),
    themes = if (isTRUE(cfg$submissions$known_themes_only)) challenge_themes(cfg)
  )
  log_step(
    "{length(keys)} object{?s} in the bucket: {plan$n_excluded} excluded, ",
    "{length(plan$stale)} already processed, {length(plan$download)} new."
  )

  # Processed submissions still in the bucket because an earlier delete failed.
  if (delete) state$delete_queue <- c(state$delete_queue, plan$stale)

  strict <- bucket_is_strict(cfg)
  ownership <- plan_bucket_ownership(
    plan$download,
    models = if (repos_enabled(cfg)) state$registry$models,
    baseline_ids = baseline_model_ids(cfg),
    strict = strict
  )
  rows <- list()
  skipped <- ownership[ownership$action == "skip", ]
  if (nrow(skipped) > 0) {
    # Not recorded: registering the model makes the file readable again.
    rows[[1]] <- results_row(skipped$key, skipped$model_id, "bucket", NA_character_,
                             "skipped", skipped$reason)
  }
  todo <- ownership[ownership$action == "process", ]
  for (i in seq_len(nrow(todo))) {
    key <- todo$key[i]
    context <- list(route = "bucket", name = key, legacy = !strict,
                    allowed = if (isTRUE(todo$registered[i])) todo$model_id[i])
    rows[[length(rows) + 1]] <- handle_submission(
      cfg, state, key, source = "bucket", sha = NA_character_, model_id = todo$model_id[i],
      fetch = function(local) remote_download(public_key(key), local),
      context = context, record_sha = FALSE, delete_after = delete, note = todo$note[i]
    )
  }
  flush_state(cfg, state)
  log_step("Bucket: {nrow(todo)} new file{?s}; {state$n_removed} deleted from the bucket.")
  dplyr::bind_rows(rows)
}

# The challenge's own baseline model ids: the CI writes these itself.
baseline_model_ids <- function(cfg) {
  as.character(unlist(purrr::map(cfg$target_groups, \(g) purrr::map(g$baselines, "model_id"))))
}

# Contributors' git repositories. The registry (and the open clones) are in
# state$registry; the registrations are published with the results by
# run_submissions().
process_repo_submissions <- function(cfg, state) {
  registry <- state$registry
  listing <- list_repo_submissions(cfg, manifest_tokens(state$record), registry)
  todo <- listing$files
  max_bytes <- config_get(cfg, "submissions", "repos", "max_file_mb") * 1e6

  log_step("Repositories: {length(registry$entries)} to read, {nrow(todo)} new file{?s}.")
  rows <- list()
  for (i in seq_len(nrow(todo))) {
    repo <- todo$repo[i]
    handle <- registry$entries[[repo]]$handle
    sha <- todo$sha[i]
    context <- list(route = "repo", name = todo$path[i], legacy = FALSE,
                    allowed = todo$allowed[[i]], max_bytes = max_bytes)
    fallback <- paste0("repo_", gsub("[^A-Za-z0-9_.-]", "_", repo))
    rows[[length(rows) + 1]] <- handle_submission(
      cfg, state, todo$key[i], source = repo, sha = sha, model_id = todo$model_id[i],
      fetch = function(local) git_blob(handle, sha, local),
      context = context,
      results_name = if (is.na(todo$model_id[i])) fallback else todo$model_id[i],
      file = todo$path[i]
    )
  }
  flush_state(cfg, state)
  dplyr::bind_rows(rows)
}
