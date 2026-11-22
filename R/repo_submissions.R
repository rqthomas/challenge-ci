# Forecasts pulled from contributors' public git repositories.
#
# This is a second source of submissions, used alongside the submissions
# bucket (see run_submissions()). A contributor
#
#   1. describes the model in `challenge-model.yaml` at the repository root
#      (every model has a repository, whichever way it submits);
#   2. says where the forecasts go: `location` in the registry is `repo` (the
#      CI reads the forecast files from the repository, in the folder named in
#      `challenge-model.yaml`, e.g. `forecasts/`) or `bucket` (the files go to
#      the submissions bucket and the repository is read only for the model
#      description);
#   3. gets the repository added to the challenge's registry (a CSV in the
#      challenge repository).
#
# Any host that serves public repositories over https works (see
# git_repos.R). The registry says *which* repositories to read; the
# repository's own file says which model ids it may submit and where. A forecast
# is only accepted when its model id is listed in a registered repository's
# `challenge-model.yaml`, so a model id cannot be submitted from anyone else's
# repository. The CI never needs a credential from the contributor.
#
# File names are free-form: a forecast is identified by the `model_id` and
# `reference_datetime` columns inside it. New files are found by comparing each
# file's path with the processed-submissions record (see read_manifest()), not
# by file dates, which the author controls. The record key is
# `<host>/<owner>/<name>/<path>`. The first version of a path wins: a later edit
# to a file already processed is ignored, as a re-upload of the same bucket key
# is.

# The registration file every contributor repository holds.
challenge_model_file <- "challenge-model.yaml"

# TRUE when the config turns the repository source on.
repos_enabled <- function(cfg) {
  !is.null(cfg$submissions$repos$registry)
}

#' Read a repository's challenge-model.yaml
#'
#' The file describes the models a repository submits to this challenge:
#'
#' ```yaml
#' challenge: neon4cast
#' models:
#'   - model_id: my_model
#'     path: forecasts/           # default
#'     long_name: My lake model   # the other keys are model metadata
#'     description: ...
#' ```
#'
#' A repository that submits to several challenges lists one such block per
#' challenge (a YAML list of them); each challenge reads only its own. Besides
#' `model_id` and `path`, the keys are the model metadata questions of
#' [registration_columns()], answered as in the registration form. `true` and
#' `false` (or `yes` and `no`) mean the form's "Yes" and "No".
#'
#' The text is parsed without evaluating anything, then checked. Errors make
#' the repository's files unusable; warnings do not.
#'
#' @param text The file's contents.
#' @inheritParams config_get
#' @return A list with `models` (a tibble with `model_id`, `path` (a folder,
#'   ending in `/`) and one character column per metadata key given) and
#'   `problems` (a tibble with `severity` and `message`, like
#'   [validate_forecast()]). `models` has no rows when there are errors.
#' @export
#' @examples
#' cfg <- list(project_id = "neon4cast")
#' text <- "challenge: neon4cast\nmodels:\n  - model_id: my_model\n"
#' parse_challenge_model(text, cfg)$models
parse_challenge_model <- function(text, cfg) {
  problems <- tibble::tibble(severity = character(), message = character())
  add <- function(severity, message) {
    new <- tibble::tibble(severity = severity, message = message)
    problems <<- dplyr::bind_rows(problems, new)
  }
  fail <- function(message) {
    add("error", message)
    list(models = empty_models(), problems = problems)
  }

  parsed <- tryCatch(yaml::yaml.load(text, eval.expr = FALSE),
                     error = function(e) e)
  if (inherits(parsed, "error")) {
    return(fail(paste("not valid YAML:", conditionMessage(parsed))))
  }
  if (!is.list(parsed)) return(fail("the file must be a YAML mapping"))

  blocks <- if (!is.null(names(parsed))) list(parsed) else parsed
  is_mine <- function(block) {
    is.list(block) && identical(as.character(block$challenge %||% NA), cfg$project_id)
  }
  mine <- Filter(is_mine, blocks)
  if (length(mine) == 0) {
    return(fail(paste0("no block with `challenge: ", cfg$project_id, "`")))
  }
  if (length(mine) > 1) return(fail("more than one block for this challenge"))
  entries <- mine[[1]]$models
  if (!is.list(entries) || length(entries) == 0 || !is.null(names(entries))) {
    return(fail("`models` must be a list with at least one model"))
  }

  known <- c("model_id", "path",
             setdiff(names(registration_columns(cfg)), c("project_id", "model_id")))
  rows <- list()
  for (entry in entries) {
    id <- entry$model_id
    if (!rlang::is_string(id) || !grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", id)) {
      add("error", paste("`model_id` must be letters, digits, `_`, `.` or `-`;",
                         "got", deparse(id)))
      next
    }
    path <- entry$path %||% "forecasts/"
    if (!rlang::is_string(path) || grepl("(^|/)\\.\\.(/|$)", path)) {
      add("error", paste0(id, ": `path` must be a folder inside the repository"))
      next
    }
    values <- entry[setdiff(names(entry), c("model_id", "path"))]
    scalar <- vapply(values, function(v) length(v) == 1 && !is.list(v), logical(1))
    if (!all(scalar)) {
      add("error", paste0(id, ": ", paste(names(values)[!scalar], collapse = ", "),
                          " must be a single value"))
      next
    }
    unknown <- setdiff(names(entry), known)
    if (length(unknown) > 0) {
      add("warning", paste0(id, ": unknown key", if (length(unknown) > 1) "s",
                            " ", paste(unknown, collapse = ", ")))
    }
    for (key in c("long_name", "description")) {
      if (is.null(entry[[key]])) add("warning", paste0(id, ": no `", key, "` given"))
    }
    rows[[length(rows) + 1]] <- tibble::as_tibble(c(
      list(model_id = id, path = normalize_repo_folder(path)),
      lapply(values, yaml_answer)
    ))
  }

  models <- dplyr::bind_rows(rows)
  if (nrow(models) > 0 && anyDuplicated(models$model_id) > 0) {
    add("error", "the same `model_id` is listed twice")
  }
  if (any(problems$severity == "error")) models <- empty_models()
  list(models = models, problems = problems)
}

# A YAML value as the registration form's answer: yes/no/true/false become
# "Yes" or "No", anything else is text.
yaml_answer <- function(value) {
  if (is.logical(value)) c("No", "Yes")[value + 1L] else as.character(value)
}

empty_models <- function() {
  tibble::tibble(model_id = character(), path = character())
}

# "forecasts", "./forecasts/" and "/forecasts" all become "forecasts/"; the
# repository root becomes "".
normalize_repo_folder <- function(path) {
  path <- sub("^(\\./|/)+", "", path)
  path <- sub("/+$", "", path)
  if (path %in% c("", ".")) "" else paste0(path, "/")
}

#' Read the registry of contributor repositories
#'
#' The registry is a CSV (a path in the challenge repository, or a URL) named
#' by `submissions$repos$registry`. One row per repository: `repo` (an
#' address such as `owner/name`, meaning GitHub, or `https://gitlab.com/group/name`,
#' see [normalize_repo()]), `location` (`repo` or `bucket`, see above; `repo`
#' when missing) and `registered` (a date, for the record). Rows whose `repo`
#' is not a valid address or whose `location` is neither value, and repeated
#' repositories, are dropped with a warning.
#'
#' @inheritParams config_get
#' @return A tibble with columns `repo` (`host/owner/name`), `location` and
#'   `registered`.
#' @export
read_forecast_repos <- function(cfg) {
  path <- config_get(cfg, "submissions", "repos", "registry")
  if (!grepl("^https?://", path) && !file.exists(path)) {
    cli::cli_abort(c(
      "The repository registry {.path {path}} does not exist.",
      "i" = "Set {.field submissions$repos$registry} to a CSV with a {.field repo} column."
    ))
  }
  registry <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                              progress = FALSE)
  if (!"repo" %in% names(registry)) {
    cli::cli_abort("The repository registry {.path {path}} has no {.field repo} column.")
  }
  for (col in setdiff(c("location", "registered"), names(registry))) {
    registry[[col]] <- NA_character_
  }
  given <- trimws(registry$repo)
  registry <- registry |>
    dplyr::mutate(
      repo = normalize_repo(given),
      location = tolower(dplyr::coalesce(trimws(.data$location), "repo")),
      location = dplyr::if_else(.data$location == "", "repo", .data$location)
    ) |>
    dplyr::select("repo", "location", "registered")
  bad_repo <- is.na(registry$repo)
  if (any(bad_repo)) {
    cli::cli_warn(
      "Ignoring registry rows that are not repository addresses: {.val {given[bad_repo]}}."
    )
  }
  bad_location <- !bad_repo & !registry$location %in% c("repo", "bucket")
  if (any(bad_location)) {
    cli::cli_warn(paste("Ignoring registry rows whose location is not {.val repo} or",
                        "{.val bucket}: {.val {registry$repo[bad_location]}}."))
  }
  registry <- registry[!bad_repo & !bad_location, ]
  if (anyDuplicated(tolower(registry$repo)) > 0) {
    cli::cli_warn("Repositories listed twice in the registry; keeping the first row of each.")
    registry <- registry[!duplicated(tolower(registry$repo)), ]
  }
  registry
}

#' Decide which files in a repository to download
#'
#' A pure function over the repository's file listing, so the rules can be
#' tested without a git host. Only `.csv` and `.csv.gz` files under a registered
#' model's folder are considered, and files already in the record are left out.
#' The size of a file is not known before it is fetched, so the size limit is
#' applied when it is processed.
#'
#' @param tree The repository's files: `path` and `sha`.
#' @param models The repository's models from [parse_challenge_model()].
#' @param repo The repository, `host/owner/name`.
#' @param blocked Tokens of the processed-submissions record (see
#'   [manifest_tokens()]). A file is left out when its key, or its key and SHA,
#'   is there.
#' @param max_files Most files to download in one run (by path); the rest are
#'   picked up by the next run.
#' @return A tibble with `key`, `path`, `sha`, `model_id` (the folder's only
#'   model, `NA` when several models share the folder) and `allowed`, a list
#'   column with the model ids the file may hold.
#' @export
plan_repo_files <- function(tree, models, repo, blocked = character(), max_files = Inf) {
  empty <- tibble::tibble(key = character(), path = character(), sha = character(),
                          model_id = character(), allowed = list())
  files <- tree[tree$type == "blob" & grepl("\\.csv(\\.gz)?$", tree$path), ]
  if (nrow(files) == 0) return(empty)

  allowed <- lapply(files$path, function(p) {
    models$model_id[vapply(models$path, function(folder) startsWith(p, folder), logical(1))]
  })
  in_folder <- lengths(allowed) > 0
  files <- files[in_folder, ]
  allowed <- allowed[in_folder]
  if (nrow(files) == 0) return(empty)

  files$key <- paste0(repo, "/", files$path)
  files$allowed <- allowed
  files$model_id <- vapply(allowed, function(a) if (length(a) == 1) a else NA_character_,
                           character(1))
  files <- files[!files$key %in% blocked & !paste0(files$key, "@", files$sha) %in% blocked, ]
  files <- files[order(files$path), ]
  files <- files[seq_len(min(nrow(files), max_files)), ]
  files[, names(empty)]
}

# Listing --------------------------------------------------------------------

# One row of what we learned about a repository, to publish to its submitter.
registration_row <- function(repo, status, reason, sha = NA_character_,
                             model_ids = NA_character_) {
  tibble::tibble(
    key = NA_character_,
    model_id = model_ids,
    file = challenge_model_file,
    source = repo,
    sha = sha,
    results_name = if (anyNA(model_ids)) {
      paste0("repo_", gsub("[^A-Za-z0-9_.-]", "_", repo))
    } else {
      model_ids
    },
    status = status,
    reason = reason,
    warnings = ""
  )
}

# Reading a repository's registration -------------------------------------------

# A repository's file list and parsed challenge-model.yaml, with the open clone
# in `handle` (the caller closes it). Returns list(info, handle, tree,
# model_file, parsed), or list(invalid = list(reason, sha)) when the repository
# cannot be used: no file, or an invalid file. A repository that cannot be
# cloned (private, missing, a host that is not allowed) is an error.
fetch_registration <- function(cfg, repo) {
  invalid <- function(reason, sha = NA_character_) {
    list(invalid = list(reason = reason, sha = sha))
  }

  handle <- git_open(repo_clone_url(cfg, repo))
  ok <- FALSE
  on.exit(if (!ok) git_close(handle))

  tree <- git_tree(handle)
  model_file <- tree[tree$path == challenge_model_file, ]
  if (nrow(model_file) == 0) {
    return(invalid(paste("no", challenge_model_file, "at the repository root")))
  }
  text <- tryCatch(git_text(handle, model_file$sha), error = function(e) conditionMessage(e))
  if (!rlang::is_string(text) || startsWith(text, "the file is larger")) {
    return(invalid(paste(challenge_model_file, "is larger than 1 MB"), model_file$sha))
  }

  parsed <- parse_challenge_model(text, cfg)
  errors <- parsed$problems$message[parsed$problems$severity == "error"]
  if (length(errors) > 0) {
    return(invalid(paste(errors, collapse = "; "), model_file$sha))
  }
  ok <- TRUE
  list(info = list(id = repo, default_branch = handle$branch, commit = handle$commit),
       handle = handle, tree = tree, model_file = model_file, parsed = parsed)
}

# A model id belongs to the first repository in the registry that lists it, so
# a second repository cannot submit as, or describe, someone else's model.
# `claimed` is a named character vector, model id = repository. Returns the
# models this repository may use, the ids it may not, and the updated `claimed`.
claim_models <- function(models, repo, claimed) {
  taken <- models$model_id %in% names(claimed)
  list(
    models = models[!taken, ],
    conflicts = rlang::set_names(unname(claimed[models$model_id[taken]]), models$model_id[taken]),
    claimed = c(claimed, rlang::set_names(rep(repo, sum(!taken)), models$model_id[!taken]))
  )
}

claim_conflict_rows <- function(repo, conflicts, sha) {
  if (length(conflicts) == 0) return(NULL)
  registration_row(
    repo, "registration_invalid",
    paste0("model_id ", names(conflicts), " is already registered to ", conflicts,
           " and is ignored here"),
    sha = sha
  )
}

#' Read every registered repository
#'
#' Opens each repository in the registry (a shallow clone, see git_repos.R),
#' reads its `challenge-model.yaml` and works out which models it may use. A
#' repository that cannot be read or whose file is invalid is reported and
#' skipped; the others carry on. A model id belongs to the first repository in
#' the registry that lists it; later repositories listing it lose it (and are
#' told). Clones of repositories whose forecast files will be read stay open
#' until [close_registry()].
#'
#' @inheritParams config_get
#' @param repos The registry. Defaults to [read_forecast_repos()].
#' @return A list with `entries` (one per usable repository: `repo`,
#'   `location`, `handle`, `tree`, `models`), `models` (every model with its
#'   `repo`, `location`, `path` and the metadata answers) and `registrations`
#'   (one row per repository outcome, in the format of the published results).
#' @export
load_registry <- function(cfg, repos = read_forecast_repos(cfg)) {
  claimed <- character()
  entries <- list()
  models <- list()
  registrations <- list()
  for (i in seq_len(nrow(repos))) {
    repo <- repos$repo[i]
    location <- repos$location[i]
    log_step("{repo}")
    reg <- tryCatch(fetch_registration(cfg, repo), error = function(e) {
      cli::cli_warn("Could not read {.val {repo}}: {conditionMessage(e)}")
      list(invalid = list(reason = paste("could not read the repository:", conditionMessage(e)),
                          sha = NA_character_))
    })
    if (!is.null(reg$invalid)) {
      registrations[[length(registrations) + 1]] <-
        registration_row(repo, "registration_invalid", reg$invalid$reason, sha = reg$invalid$sha)
      next
    }

    claim <- claim_models(reg$parsed$models, repo, claimed)
    claimed <- claim$claimed
    registrations[[length(registrations) + 1]] <-
      claim_conflict_rows(repo, claim$conflicts, reg$model_file$sha)
    if (nrow(claim$models) == 0) {
      git_close(reg$handle)
      next
    }

    registered <- registration_row(
      repo, "registered",
      if (location == "bucket") "forecasts are submitted to the submissions bucket" else "",
      sha = reg$model_file$sha, model_ids = claim$models$model_id
    )
    problems <- reg$parsed$problems
    registered$warnings <- paste(problems$message[problems$severity == "warning"],
                                 collapse = "; ")
    registrations[[length(registrations) + 1]] <- registered

    one <- claim$models
    one$repo <- rep(repo, nrow(one))
    one$location <- rep(location, nrow(one))
    models[[length(models) + 1]] <- one
    # Only a repository whose files are read keeps its clone.
    if (location == "repo") {
      entries[[repo]] <- list(repo = repo, location = location, handle = reg$handle,
                              tree = reg$tree, models = claim$models)
    } else {
      git_close(reg$handle)
    }
  }
  list(entries = entries,
       models = dplyr::bind_rows(models),
       registrations = dplyr::bind_rows(registrations))
}

#' @rdname load_registry
#' @param registry The result of `load_registry()`.
#' @export
close_registry <- function(registry) {
  for (entry in registry$entries) git_close(entry$handle)
  invisible(NULL)
}

#' List the new submissions in the registered repositories
#'
#' For each repository whose `location` is `repo`, picks the new files with
#' [plan_repo_files()]. Repositories with `location` `bucket` have no files
#' here; their models are in `registry$models`.
#'
#' @inheritParams config_get
#' @param blocked Tokens of the processed-submissions record, see
#'   [manifest_tokens()].
#' @param registry From [load_registry()].
#' @return A list with `files` (what to download, with `repo` and the columns of
#'   [plan_repo_files()]) and `registrations` (one row per repository outcome).
#' @export
list_repo_submissions <- function(cfg, blocked, registry) {
  settings <- config_get(cfg, "submissions", "repos")
  files <- lapply(registry$entries, function(entry) {
    plan <- plan_repo_files(entry$tree, entry$models, entry$repo, blocked = blocked,
                            max_files = settings$max_files_per_repo)
    plan$repo <- rep(entry$repo, nrow(plan))
    plan
  })
  files <- dplyr::bind_rows(files)
  if (nrow(files) == 0) {
    files <- tibble::tibble(key = character(), path = character(), sha = character(),
                            model_id = character(), allowed = list(), repo = character())
  }
  list(files = files, registrations = registry$registrations)
}

#' Models described by the registered repositories
#'
#' Reads the `challenge-model.yaml` of every repository in the registry and
#' returns the models it lists, with the metadata given there. A repository
#' that cannot be read is skipped with a warning, and a model id listed by
#' more than one repository belongs to the first in the registry, as when
#' reading submissions. This is where the model metadata of models submitted
#' from a repository, or by a repository's owner to the bucket, comes from (see
#' [read_registered_models()]).
#'
#' @inheritParams config_get
#' @param repos The registry. Defaults to [read_forecast_repos()].
#' @return A tibble with the columns of [registration_columns()] (`NA` for
#'   questions not answered), `project_id` set to the challenge's, and `repo`
#'   (`host/owner/name`).
#' @export
read_repo_models <- function(cfg, repos = read_forecast_repos(cfg)) {
  columns <- names(registration_columns(cfg))
  registry <- load_registry(cfg, repos)
  on.exit(close_registry(registry))
  models <- registry$models
  if (nrow(models) == 0) models <- empty_models()
  if (!"repo" %in% names(models)) models$repo <- character(nrow(models))
  for (col in setdiff(c(columns, "repo"), names(models))) models[[col]] <- NA_character_
  models$project_id <- rep(cfg$project_id, nrow(models))
  dplyr::select(models, dplyr::all_of(c(columns, "repo")))
}
