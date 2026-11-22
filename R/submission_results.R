# Publishing what happened to each submitted file, so that submitters can see
# it. A submitter who pushes a file to a GitHub repository gets no response;
# without this, a file that failed validation would just never appear. The
# challenge cannot write to the submitter's repository (that would need their
# credentials), so the outcome is published next to the forecasts instead.

# The columns of one row of results, as run_submissions() builds them.
results_row <- function(key, model_id, source, sha, status, reason, warnings = "",
                        file = key, results_name = model_id,
                        rows_kept = NA_integer_, rows_dropped = NA_integer_) {
  tibble::tibble(key = key, model_id = model_id, file = file, source = source,
                 sha = sha, results_name = results_name, status = status,
                 reason = reason, warnings = warnings,
                 rows_kept = as.integer(rows_kept), rows_dropped = as.integer(rows_dropped))
}

empty_results <- function() {
  results_row(character(), character(), character(), character(), character(),
              character())
}

# Columns kept in the published files.
published_columns <- c("model_id", "file", "source", "sha", "first_seen",
                       "status", "reason", "warnings", "rows_kept", "rows_dropped")

#' Publish what happened to each submitted file
#'
#' Writes one CSV per model to `<forecasts_bucket>/submission_results/`,
#' named `<model_id>.csv`, so a submitter can check whether a file was
#' accepted and why not. It has one row per outcome:
#'
#' * `model_id`, `file`: the model and the file's path in its source.
#' * `source`: `bucket`, or the repository the file came from, as
#'   `<host>/<owner>/<name>` (for example `github.com/alice/forecasts`).
#' * `sha`: the file's git blob SHA (repository) or MD5 (bucket).
#' * `first_seen`: when the CI first saw this outcome (UTC). For a processed
#'   file this is its publication time.
#' * `status`: `processed`, `invalid`, `skipped`, `unreadable` or `failed`; for
#'   a repository, `registered` or `registration_invalid`.
#' * `reason`, `warnings`: why, and any non-fatal problems, including rows
#'   dropped because they are not this challenge's.
#' * `rows_kept`, `rows_dropped`: how many rows of the file were stored and not
#'   (empty for a file that was not read).
#'
#' A repository whose `challenge-model.yaml` cannot be read is reported under
#' `repo_<host>_<owner>_<name>.csv`, since it has no model id yet. So is a file in
#' a folder shared by several models whose model could not be read. The same outcome is
#' never written twice (same file, source, SHA and status), so a file that is
#' skipped on every run appears once; a retry after a failure that ends the
#' same way is not repeated either. Each file keeps the most recent
#' `submissions$results_max_rows` rows.
#'
#' Publishing is best effort: a failure is a warning, never fails the run.
#' Dry runs write to the dry-run folder like every other upload.
#'
#' @inheritParams config_get
#' @param results Rows from [run_submissions()] (with `results_name`, the name
#'   of the file to publish them in; rows without one are not published).
#' @return The remote paths written, invisibly.
#' @export
write_submission_results <- function(cfg, results) {
  results <- results[!is.na(results$results_name) & nzchar(results$results_name), ]
  if (nrow(results) == 0) return(invisible(character()))
  results$first_seen <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  max_rows <- config_get(cfg, "submissions", "results_max_rows", default = 200)

  written <- character()
  for (name in unique(results$results_name)) {
    remote <- bucket_uri(cfg, "forecasts_bucket", "submission_results",
                         paste0(gsub("[^A-Za-z0-9_.-]", "_", name), ".csv"),
                         scheme = "remote")
    tryCatch({
      new <- results[results$results_name == name, published_columns] |>
        dplyr::mutate(dplyr::across(dplyr::everything(), as.character))
      combined <- dplyr::bind_rows(read_published_results(remote), new) |>
        dplyr::distinct(.data$file, .data$source, .data$sha, .data$status,
                        .keep_all = TRUE)
      combined <- utils::tail(combined, max_rows)
      local <- tempfile(fileext = ".csv")
      on.exit(unlink(local), add = TRUE)
      readr::write_csv(combined, local)
      upload_file(local, remote)
      written <- c(written, remote)
    }, error = function(e) {
      cli::cli_warn("Could not publish the results for {.val {name}}: {conditionMessage(e)}")
    })
  }
  invisible(written)
}

# The results already published at `remote`, or none.
read_published_results <- function(remote) {
  if (!remote_exists(remote)) {
    empty <- rep(list(character()), length(published_columns))
    return(tibble::as_tibble(rlang::set_names(empty, published_columns)))
  }
  local <- tempfile(fileext = ".csv")
  on.exit(unlink(local))
  remote_download(remote, local)
  published <- readr::read_csv(local, col_types = readr::cols(.default = "c"), progress = FALSE)
  # Files written before a column existed.
  for (col in setdiff(published_columns, names(published))) published[[col]] <- NA_character_
  published
}
