# Processing new submissions: download from the submissions bucket and, when the
# config turns it on, from contributors' GitHub repositories (see
# github_submissions.R); check, standardise, and write to the forecasts bucket as
# parquet plus summaries. Both sources share one processed-submissions record.
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

# minio client aliases used for the submissions bucket.
submissions_alias <- "submissions"
submissions_public_alias <- "submissions_public"

#' Read the record of processed submissions
#'
#' Only a record that does not exist yet starts a new, empty one. Any other
#' error (access, network) stops the run, because carrying on with an empty
#' record would overwrite the real one and reprocess every submission.
#'
#' @inheritParams config_get
#' @return Character vector of processed submission keys.
#' @export
read_manifest <- function(cfg) {
  remote <- bucket_uri(cfg, "processed_submissions", scheme = "mc")
  if (length(minioclient::mc_ls(remote)) == 0) {
    cli::cli_inform("No processed-submissions record found; starting a new one.")
    return(character(0))
  }
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  minioclient::mc_cp(remote, local)
  manifest <- readr::read_csv(local, show_col_types = FALSE, progress = FALSE)
  if (!"key" %in% names(manifest)) {
    cli::cli_abort("Processed-submissions record {.path {remote}} has no {.field key} column.")
  }
  as.character(manifest$key)
}

#' @rdname read_manifest
#' @param keys All processed keys, to write as the new record.
#' @export
write_manifest <- function(cfg, keys) {
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  readr::write_csv(tibble::tibble(key = keys), local)
  upload_file(local, bucket_uri(cfg, "processed_submissions", scheme = "mc"))
}

#' Decide which submissions to download
#'
#' @param keys Every key in the submissions bucket.
#' @param processed Keys already in the processed-submissions record.
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

#' Process one downloaded submission
#'
#' Checks the file name, then reads, validates and standardises the forecast.
#' For a valid forecast, writes parquet and summaries under `out_dir` (in
#' `parquet/` and `summaries/`) ready to upload.
#'
#' @param path Local path of the downloaded file.
#' @inheritParams config_get
#' @param out_dir Local folder for the output.
#' @param pub_datetime Publication time stamped on the forecast.
#' @return A list with `status` and `reason`, and `warnings` (the validation
#'   warnings, joined) when the file was read. `status` is `"processed"`, or
#'   `"invalid"` (failed validation) or `"skipped"` (a file name, type or date
#'   that is not processed). Errors are raised, not returned, so a failure can
#'   be retried on the next run.
#' @export
process_submission <- function(path, cfg, out_dir, pub_datetime = Sys.time()) {
  info <- parse_submission_filename(path)
  min_date <- config_get(cfg, "submissions", "min_reference_date", default = NA)

  if (is.na(info$model_id)) {
    return(list(status = "skipped",
                reason = "name is not <theme>-<YYYY-MM-DD>-<model_id>.<ext>"))
  }
  if (!info$extension %in% c("csv", "csv.gz")) {
    return(list(status = "skipped",
                reason = paste0(".", info$extension, " files are not accepted")))
  }
  if (!is.na(min_date) && as.Date(info$reference_datetime) < as.Date(min_date)) {
    return(list(status = "skipped", reason = paste("reference date before", min_date)))
  }

  fc <- read_submission(path)
  problems <- validate_forecast(fc, cfg)
  for (i in seq_len(nrow(problems))) {
    cli::cli_inform(c("!" = "{problems$severity[i]}: {problems$message[i]}"))
  }
  warned <- paste(problems$message[problems$severity == "warning"], collapse = "; ")
  if (any(problems$severity == "error")) {
    return(list(status = "invalid",
                reason = paste(problems$message[problems$severity == "error"],
                               collapse = "; "),
                warnings = warned))
  }

  fc <- standardize_forecast(fc, cfg, info, pub_datetime = pub_datetime)
  file_id <- paste0("sub_", unname(tools::md5sum(path)))
  write_forecast_parquet(fc, file.path(out_dir, "parquet"), file_id)
  write_forecast_parquet(summarize_submission(fc), file.path(out_dir, "summaries"), file_id)
  list(status = "processed", reason = paste(nrow(fc), "rows"), warnings = warned)
}

#' Process all new submissions
#'
#' The `submissions` stage. New files come from up to two sources, used
#' together:
#'
#' * the submissions bucket (unless `submissions$use_bucket` is `false`);
#' * the contributors' GitHub repositories listed in the registry named by
#'   `submissions$github$registry`, when that is set (see
#'   [list_github_submissions()]).
#'
#' For each new file:
#'
#' 1. download it (a file that cannot be read is skipped and retried next run);
#' 2. [process_submission()] it, and upload any parquet and summaries to the
#'    forecasts and summaries buckets;
#' 3. archive the raw file in `<forecasts_bucket>/raw/`, valid or not;
#' 4. add it to the processed-submissions record and, for the bucket, delete it
#'    there (best effort).
#'
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
  mc_connect(cfg, "main", anonymous = is_dry_run() && read_anonymously_without_key(cfg))

  use_bucket <- isTRUE(config_get(cfg, "submissions", "use_bucket", default = TRUE))
  use_github <- github_enabled(cfg)
  if (!use_bucket && !use_github) {
    cli::cli_abort(paste("No submission source is on: set {.field submissions$github$registry}",
                         "or leave {.field submissions$use_bucket} true."))
  }

  state <- list(
    processed = read_manifest(cfg),
    work_dir = tempfile("submissions"),
    time_stamp = format(Sys.time(), "%Y%m%d%H%M%S")
  )
  on.exit(unlink(state$work_dir, recursive = TRUE), add = TRUE)

  results <- list()
  source_errors <- character()
  run_source <- function(name, fun) {
    log_step("Source: {name}")
    out <- tryCatch(fun(cfg, state), error = function(e) {
      cli::cli_alert_danger("Source {name} failed: {conditionMessage(e)}")
      source_errors <<- c(source_errors, paste0(name, ": ", conditionMessage(e)))
      NULL
    })
    if (!is.null(out)) {
      state$processed <<- out$processed
      results[[name]] <<- out$results
    }
  }
  if (use_bucket) run_source("bucket", process_bucket_submissions)
  if (use_github) run_source("github", process_github_submissions)

  results <- dplyr::bind_rows(results)
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

# Process a downloaded file and put everything it produces in its place:
# parquet and summaries (when valid) and the raw archive copy. Returns the
# outcome of process_submission(). Errors propagate, so the caller can leave the
# file out of the record and retry it.
store_submission <- function(cfg, local, key, out_dir, time_stamp) {
  outcome <- process_submission(local, cfg, out_dir)
  if (outcome$status == "processed") {
    upload_dir(file.path(out_dir, "parquet"),
               bucket_uri(cfg, "forecasts_bucket", "parquet", scheme = "mc"))
    upload_dir(file.path(out_dir, "summaries"),
               bucket_uri(cfg, "summaries_bucket", "summaries", scheme = "mc"))
  }
  upload_file(local, bucket_uri(cfg, "forecasts_bucket", "raw",
                                paste0("T", time_stamp, "_", basename(key)),
                                scheme = "mc"))
  outcome
}

# Download and process one file. `fetch(local)` downloads it (errors mean
# "unreadable"); `after_record()` runs once the file is in the record. Returns
# list(row, processed): the results row and the updated record.
handle_submission <- function(cfg, state, processed, key, source, sha, model_id,
                              fetch, after_record = function() NULL) {
  log_step("{key}")
  local <- file.path(state$work_dir, "raw", key)
  dir.create(dirname(local), recursive = TRUE, showWarnings = FALSE)
  out_dir <- tempfile("out", tmpdir = state$work_dir)
  on.exit(unlink(c(local, out_dir), recursive = TRUE), add = TRUE)

  downloaded <- tryCatch({
    fetch(local)
    TRUE
  }, error = function(e) {
    cli::cli_warn("Could not download {.path {key}}: {conditionMessage(e)}")
    FALSE
  })
  if (!downloaded) {
    return(list(processed = processed,
                row = results_row(key, model_id, source, sha, "unreadable",
                                  "download failed")))
  }
  if (is.na(sha)) sha <- unname(tools::md5sum(local))

  result <- tryCatch({
    outcome <- store_submission(cfg, local, key, out_dir, state$time_stamp)
    # Record first, delete second: if the delete succeeded but the record
    # was never written, the submission would be lost rather than retried.
    recorded <- unique(c(processed, key))
    write_manifest(cfg, recorded)
    processed <- recorded
    after_record()
    outcome
  }, error = function(e) list(status = "failed", reason = conditionMessage(e)))
  if (result$status != "processed") {
    cli::cli_inform(c("!" = "{result$status}: {result$reason}"))
  }
  list(processed = processed,
       row = results_row(key, model_id, source, sha, result$status, result$reason,
                         result$warnings %||% ""))
}

# The submissions bucket: list with the key, read and delete anonymously (see
# the note at the top of this file).
process_bucket_submissions <- function(cfg, state) {
  mc_connect(cfg, "submissions", alias = submissions_alias)
  mc_connect(cfg, "submissions", alias = submissions_public_alias, anonymous = TRUE)

  bucket <- config_get(cfg, "submissions_bucket")
  public_key <- function(key) paste0(submissions_public_alias, "/", bucket, "/", key)
  remove_submission <- function(key) {
    tryCatch(
      {
        remove_remote(public_key(key))
        TRUE
      },
      error = function(e) {
        cli::cli_warn(
          "Could not delete {.path {key}} from the submissions bucket: {conditionMessage(e)}"
        )
        FALSE
      }
    )
  }

  processed <- state$processed
  keys <- remote_files(paste0(submissions_alias, "/", bucket))$key
  plan <- plan_submissions(
    keys, processed,
    exclude_patterns = unlist(config_get(cfg, "submissions", "exclude_patterns",
                                         default = character())),
    themes = if (isTRUE(cfg$submissions$known_themes_only)) challenge_themes(cfg)
  )
  log_step(
    "{length(keys)} object{?s} in the bucket: {plan$n_excluded} excluded, ",
    "{length(plan$stale)} already processed, {length(plan$download)} new."
  )

  # Processed submissions still in the bucket because an earlier delete failed.
  n_removed <- sum(vapply(plan$stale, remove_submission, logical(1)))

  rows <- vector("list", length(plan$download))
  for (i in seq_along(plan$download)) {
    key <- plan$download[i]
    handled <- handle_submission(
      cfg, state, processed, key, source = "bucket", sha = NA_character_,
      model_id = parse_submission_filename(key)$model_id,
      fetch = function(local) minioclient::mc_cp(public_key(key), shQuote(local)),
      after_record = function() n_removed <<- n_removed + remove_submission(key)
    )
    processed <- handled$processed
    rows[[i]] <- handled$row
  }
  log_step("Bucket: {length(plan$download)} new file{?s}; {n_removed} deleted from the bucket.")
  list(results = dplyr::bind_rows(rows), processed = processed)
}

# Contributors' GitHub repositories.
process_github_submissions <- function(cfg, state) {
  processed <- state$processed
  listing <- list_github_submissions(cfg, processed)
  files <- listing$files

  # Files to report but not download (unusable name, unlisted model, too big).
  # They are not recorded, so the submitter can fix the file or the listing;
  # the published results keep one row per outcome, not one per run.
  skipped <- files[files$action == "skip", ]
  rows <- list(listing$registrations)
  if (nrow(skipped) > 0) {
    rows[[2]] <- results_row(skipped$key, skipped$model_id,
                             paste0("github:", skipped$repo), skipped$sha,
                             "skipped", skipped$reason, file = skipped$path)
  }

  todo <- files[files$action == "download", ]
  log_step("GitHub: {nrow(listing$registrations)} repositor{?y/ies}, {nrow(todo)} new file{?s}.")
  for (i in seq_len(nrow(todo))) {
    handled <- handle_submission(
      cfg, state, processed, todo$key[i], source = paste0("github:", todo$repo[i]),
      sha = todo$sha[i], model_id = todo$model_id[i],
      fetch = function(local) github_blob(todo$repo[i], todo$sha[i], local)
    )
    processed <- handled$processed
    rows[[length(rows) + 1]] <- dplyr::mutate(handled$row, file = todo$path[i])
  }
  list(results = dplyr::bind_rows(rows), processed = processed)
}
