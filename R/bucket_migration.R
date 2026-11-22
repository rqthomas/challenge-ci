# Helpers for moving teams that submit to the bucket onto the registry: every
# model needs a repository with a challenge-model.yaml (see
# repo_submissions.R). Both only read.

#' Draft a challenge-model.yaml from a model's registration-form answers
#'
#' A team that registered through the form already answered the questions
#' `challenge-model.yaml` carries. This turns those answers into a starter file
#' for the team to put at the root of their repository. Yes and No answers
#' become `true` and `false`; unanswered questions are left out.
#'
#' @inheritParams config_get
#' @param model_id The model.
#' @param sheet The registration sheet, if already read (see
#'   [read_sheet_models()]).
#' @param file If given, the draft is also written there.
#' @return The text of the file, invisibly.
#' @export
draft_challenge_model <- function(cfg, model_id, sheet = NULL, file = NULL) {
  models <- read_sheet_models(cfg, sheet)
  row <- models[models$model_id == model_id, ]
  if (nrow(row) == 0) {
    cli::cli_abort(
      "{.val {model_id}} is not in the registration sheet for {.val {cfg$project_id}}."
    )
  }
  answers <- as.list(row[1, setdiff(names(row), c("project_id", "model_id"))])
  answers <- answers[!vapply(answers, function(a) is.na(a) || !nzchar(trimws(a)), logical(1))]
  answers <- lapply(answers, function(a) switch(a, Yes = TRUE, No = FALSE, a))
  entry <- c(list(model_id = model_id, path = "forecasts/"), answers)
  body <- yaml::as.yaml(list(challenge = cfg$project_id, models = list(entry)))
  text <- paste0(
    "# Save as challenge-model.yaml at the root of your repository, check the answers,\n",
    "# and register the repository with the challenge. `path` is where forecast files\n",
    "# are if you send them through the repository; `location: bucket` in the\n",
    "# registry keeps sending them to the submissions bucket.\n",
    body
  )
  if (!is.null(file)) writeLines(text, file)
  invisible(text)
}

# Model ids with forecasts stored for the challenge.
published_model_ids <- function(cfg) {
  summaries <- bucket_uri(cfg, "summaries_bucket", "summaries")
  duckdbfs::open_dataset(file.path(summaries, "**"), format = "parquet", hive_style = TRUE) |>
    dplyr::filter(.data$project_id == !!cfg$project_id) |>
    dplyr::distinct(.data$model_id) |>
    dplyr::collect() |>
    dplyr::pull("model_id")
}

#' Published models that no registered repository claims
#'
#' The models with forecasts stored for the challenge, less the ones a registered
#' repository's `challenge-model.yaml` lists and the challenge's own baselines.
#' These are the teams to ask to register before
#' `submissions$bucket$strict_from`. Their contact and code link come from the
#' registration sheet when they filled in the form.
#'
#' @inheritParams config_get
#' @param registry The registry from [load_registry()]; read (and closed) when
#'   `NULL`.
#' @param sheet The registration sheet, if already read.
#' @return A tibble with `model_id`, `contact_name` and `code_url` (`NA` when the
#'   model is not in the sheet).
#' @export
unregistered_bucket_models <- function(cfg, registry = NULL, sheet = NULL) {
  if (is.null(registry)) {
    registry <- load_registry(cfg)
    on.exit(close_registry(registry))
  }
  ids <- setdiff(published_model_ids(cfg), c(registry$models$model_id, baseline_model_ids(cfg)))
  known <- tryCatch(read_sheet_models(cfg, sheet), error = function(e) NULL)
  out <- tibble::tibble(model_id = sort(ids))
  for (col in c("contact_name", "code_url")) {
    values <- known[[col]][match(out$model_id, known$model_id)]
    out[[col]] <- if (is.null(values)) rep(NA_character_, nrow(out)) else values
  }
  out
}
