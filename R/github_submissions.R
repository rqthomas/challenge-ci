# Forecasts pulled from contributors' public GitHub repositories.
#
# This is an optional second source of submissions, used alongside the
# submissions bucket (see run_submissions()). A contributor
#
#   1. keeps forecasts in a public repository, in a folder such as
#      `forecasts/`, named <theme>-<YYYY-MM-DD>-<model_id>.csv[.gz];
#   2. describes the model in `challenge-model.yaml` at the repository root;
#   3. gets the repository added to the challenge's registry (a CSV in the
#      challenge repository).
#
# The registry says *which* repositories to read; the repository's own file
# says which model ids it may submit and where. A file is only accepted when
# its model id is listed in that repository's `challenge-model.yaml`, so a
# model id cannot be submitted from anyone else's repository. The CI never
# needs a credential from the contributor: only public data is read.
#
# New files are found by comparing each file's git blob SHA and path with the
# processed-submissions record (see read_manifest()), not by file dates, which
# the author controls. The record key is `github/<repo_id>/<path>`, built on
# the numeric repository id so that renaming a repository does not make its
# files look new. The first version of a path wins: a later edit to a file
# already processed is ignored, as a re-upload of the same bucket key is.

# The registration file every contributor repository holds.
challenge_model_file <- "challenge-model.yaml"

# TRUE when the config turns the GitHub source on.
github_enabled <- function(cfg) {
  !is.null(cfg$submissions$github$registry)
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
#' by `submissions$github$registry`. One row per repository: `repo`
#' (`owner/name`), optionally `repo_id` (GitHub's numeric id, which stays the
#' same when a repository is renamed or transferred; when given it must match)
#' and `registered` (a date, for the record). Rows whose `repo` is not
#' `owner/name`, and repeated repositories, are dropped with a warning.
#'
#' @inheritParams config_get
#' @return A tibble with columns `repo`, `repo_id` (character, `NA` when not
#'   recorded) and `registered`.
#' @export
read_forecast_repos <- function(cfg) {
  path <- config_get(cfg, "submissions", "github", "registry")
  if (!grepl("^https?://", path) && !file.exists(path)) {
    cli::cli_abort(c(
      "The GitHub registry {.path {path}} does not exist.",
      "i" = "Set {.field submissions$github$registry} to a CSV with a {.field repo} column."
    ))
  }
  registry <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                              progress = FALSE)
  if (!"repo" %in% names(registry)) {
    cli::cli_abort("The GitHub registry {.path {path}} has no {.field repo} column.")
  }
  for (col in setdiff(c("repo_id", "registered"), names(registry))) {
    registry[[col]] <- NA_character_
  }
  registry <- registry |>
    dplyr::mutate(repo = trimws(.data$repo)) |>
    dplyr::select("repo", "repo_id", "registered")
  valid <- grepl("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", registry$repo)
  if (any(!valid)) {
    cli::cli_warn(
      "Ignoring registry rows that are not {.code owner/name}: {.val {registry$repo[!valid]}}."
    )
  }
  registry <- registry[valid, ]
  if (anyDuplicated(tolower(registry$repo)) > 0) {
    cli::cli_warn("Repositories listed twice in the registry; keeping the first row of each.")
    registry <- registry[!duplicated(tolower(registry$repo)), ]
  }
  registry
}

#' Decide which files in a repository to download
#'
#' A pure function over the repository's file listing, so the rules can be
#' tested without GitHub. Only `.csv` and `.csv.gz` files under a registered
#' model's folder are considered; files of other challenges' themes (a
#' repository can serve several challenges) and files already processed are
#' left out silently. Every other file gets a row: `download`, or a `skip`
#' with the reason, which is published to the submitter.
#'
#' @param tree The repository's files: `path`, `type`, `sha` and `size`.
#' @param models The repository's models from [parse_challenge_model()].
#' @param repo_id GitHub's numeric id of the repository.
#' @param processed Keys already in the processed-submissions record.
#' @param themes Themes of this challenge's target groups. Files whose name
#'   starts with another theme are left out.
#' @param max_bytes Largest file downloaded.
#' @param max_files Most files to download in one run (oldest names first);
#'   the rest are picked up by the next run.
#' @return A tibble with `key`, `path`, `sha`, `size`, `model_id`, `action`
#'   (`"download"` or `"skip"`) and `reason`.
#' @export
plan_github_files <- function(tree, models, repo_id, processed = character(),
                              themes = NULL, max_bytes = 100e6, max_files = Inf) {
  empty <- tibble::tibble(key = character(), path = character(), sha = character(),
                          size = numeric(), model_id = character(),
                          action = character(), reason = character())
  files <- tree[tree$type == "blob" & grepl("\\.csv(\\.gz)?$", tree$path), ]
  in_folder <- vapply(files$path, function(p) any(startsWith(p, models$path)), logical(1))
  files <- files[in_folder, ]
  if (nrow(files) == 0) return(empty)

  info <- parse_submission_filename(files$path)
  files$key <- paste0("github/", repo_id, "/", files$path)
  files$model_id <- info$model_id
  keep <- !files$key %in% processed
  if (!is.null(themes)) keep <- keep & (is.na(info$theme) | info$theme %in% themes)
  files <- files[keep, ]
  info <- info[keep, ]
  if (nrow(files) == 0) return(empty)

  reason <- rep(NA_character_, nrow(files))
  bad_name <- is.na(info$model_id)
  reason[bad_name] <- "name is not <theme>-<YYYY-MM-DD>-<model_id>.<ext>"
  # A file's model must be listed for the folder the file is in.
  allowed <- vapply(seq_len(nrow(files)), function(i) {
    folders <- models$path[models$model_id == files$model_id[i]]
    any(startsWith(files$path[i], folders))
  }, logical(1))
  not_listed <- !bad_name & !allowed
  reason[not_listed] <- paste("model_id is not listed for this folder in",
                              challenge_model_file)
  too_big <- is.na(reason) & !is.na(files$size) & files$size > max_bytes
  reason[too_big] <- paste0("file is larger than ", round(max_bytes / 1e6), " MB")

  # A file with an unusable name belongs to the repository's only model, if it
  # has just one, so the submitter sees the message.
  if (nrow(models) == 1) files$model_id[bad_name] <- models$model_id

  files$action <- ifelse(is.na(reason), "download", "skip")
  files$reason <- reason
  files <- files[order(files$path), ]
  n_download <- cumsum(files$action == "download")
  files$action[files$action == "download" & n_download > max_files] <- "later"
  files <- files[files$action != "later", ]
  files[, names(empty)]
}

# GitHub API ----------------------------------------------------------------

# Token for the GitHub API, if one is set. Reading public repositories works
# without one, but only 60 requests an hour are allowed; the Actions token
# (GITHUB_PAT in the workflows) allows far more.
github_token <- function() {
  for (name in c("GITHUB_PAT", "GITHUB_TOKEN", "GH_TOKEN")) {
    token <- Sys.getenv(name)
    if (nzchar(token)) return(token)
  }
  NULL
}

github_request <- function(path, accept = "application/vnd.github+json") {
  req <- httr2::request("https://api.github.com") |>
    httr2::req_url_path_append(path) |>
    httr2::req_headers(Accept = accept, `X-GitHub-Api-Version` = "2022-11-28") |>
    httr2::req_user_agent("challengeci (https://github.com/eco4cast/challenge-ci)") |>
    httr2::req_retry(max_tries = 3)
  token <- github_token()
  if (!is.null(token)) req <- httr2::req_auth_bearer_token(req, token)
  req
}

# Id, default branch and visibility of a repository.
github_repo_info <- function(repo) {
  info <- github_request(paste0("repos/", repo)) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  list(id = as.character(info$id), full_name = info$full_name,
       default_branch = info$default_branch, private = isTRUE(info$private))
}

# Every file at the tip of a branch, with its blob SHA and size.
github_tree <- function(repo, branch) {
  branch <- utils::URLencode(branch, reserved = TRUE)
  body <- github_request(paste0("repos/", repo, "/git/trees/", branch)) |>
    httr2::req_url_query(recursive = 1) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  if (isTRUE(body$truncated)) {
    cli::cli_warn(paste("The file list of {.val {repo}} is too long for GitHub to return",
                        "in full; some files are not seen."))
  }
  tibble::tibble(
    path = vapply(body$tree, function(x) x$path, character(1)),
    type = vapply(body$tree, function(x) x$type, character(1)),
    sha = vapply(body$tree, function(x) x$sha, character(1)),
    size = vapply(body$tree, function(x) as.numeric(x$size %||% NA), numeric(1))
  )
}

# Download one file by its blob SHA. A blob is immutable, so this fetches the
# file exactly as listed even if the branch has moved on since.
github_blob <- function(repo, sha, dest) {
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  github_request(paste0("repos/", repo, "/git/blobs/", sha),
                 accept = "application/vnd.github.raw+json") |>
    httr2::req_perform(path = dest)
  invisible(dest)
}

github_text <- function(repo, sha) {
  path <- tempfile()
  on.exit(unlink(path))
  github_blob(repo, sha, path)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Listing --------------------------------------------------------------------

# One row of what we learned about a repository, to publish to its submitter.
registration_row <- function(repo, repo_id, status, reason, sha = NA_character_,
                             model_ids = NA_character_) {
  tibble::tibble(
    key = NA_character_,
    model_id = model_ids,
    file = challenge_model_file,
    source = paste0("github:", repo),
    sha = sha,
    results_name = if (anyNA(model_ids)) {
      paste0("github_", repo_id %||% gsub("/", "_", repo))
    } else {
      model_ids
    },
    status = status,
    reason = reason,
    warnings = ""
  )
}

# Reading a repository's registration -------------------------------------------

# A repository's public details, file list and parsed challenge-model.yaml.
# Returns list(info, tree, model_file, parsed), or list(invalid = list(id,
# reason, sha)) when the repository cannot be used: private, not the registered
# repository, no file, or an invalid file.
fetch_registration <- function(cfg, repo, registered_id = NA_character_) {
  invalid <- function(id, reason, sha = NA_character_) {
    list(invalid = list(id = id, reason = reason, sha = sha))
  }

  info <- github_repo_info(repo)
  if (info$private) {
    return(invalid(info$id, "the repository is private; only public repositories are read"))
  }
  if (!is.na(registered_id) && registered_id != info$id) {
    return(invalid(registered_id, paste("the repository id differs from the one registered;",
                                        "ask the challenge to update the registry")))
  }

  tree <- github_tree(repo, info$default_branch)
  model_file <- tree[tree$path == challenge_model_file & tree$type == "blob", ]
  if (nrow(model_file) == 0) {
    return(invalid(info$id, paste("no", challenge_model_file, "at the repository root")))
  }
  if (!is.na(model_file$size) && model_file$size > 1e6) {
    return(invalid(info$id, paste(challenge_model_file, "is larger than 1 MB"),
                   model_file$sha))
  }

  parsed <- parse_challenge_model(github_text(repo, model_file$sha), cfg)
  errors <- parsed$problems$message[parsed$problems$severity == "error"]
  if (length(errors) > 0) {
    return(invalid(info$id, paste(errors, collapse = "; "), model_file$sha))
  }
  list(info = info, tree = tree, model_file = model_file, parsed = parsed)
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

claim_conflict_rows <- function(repo, repo_id, conflicts, sha) {
  if (length(conflicts) == 0) return(NULL)
  registration_row(
    repo, repo_id, "registration_invalid",
    paste0("model_id ", names(conflicts), " is already registered to ", conflicts,
           " and is ignored here"),
    sha = sha
  )
}

#' List the new submissions in the registered GitHub repositories
#'
#' For each repository in the registry: checks that it is public and still
#' the repository registered (by id), reads its `challenge-model.yaml`, lists
#' its files and picks the new ones with [plan_github_files()]. A repository
#' that cannot be read or whose file is invalid is reported and skipped; the
#' others carry on. A model id belongs to the first repository in the registry
#' that lists it; later repositories listing it lose it (and are told).
#'
#' @inheritParams config_get
#' @param processed Keys already in the processed-submissions record.
#' @param repos The registry. Defaults to [read_forecast_repos()].
#' @return A list with `files` (what to download, with `repo`, `repo_id` and the
#'   columns of [plan_github_files()]; files to report but not download have
#'   `action = "skip"`) and `registrations` (one row per repository outcome,
#'   in the format of the published results).
#' @export
list_github_submissions <- function(cfg, processed, repos = read_forecast_repos(cfg)) {
  files <- list()
  registrations <- list()
  claimed <- character()
  for (i in seq_len(nrow(repos))) {
    log_step("{repos$repo[i]}")
    one <- read_github_repo(cfg, repos$repo[i], repos$repo_id[i], processed, claimed)
    registrations[[i]] <- one$registration
    if (!is.null(one$files)) files[[i]] <- one$files
    claimed <- one$claimed %||% claimed
  }

  files <- dplyr::bind_rows(files)
  if (nrow(files) == 0) {
    files <- tibble::tibble(key = character(), path = character(), sha = character(),
                            size = numeric(), model_id = character(),
                            action = character(), reason = character(),
                            repo = character(), repo_id = character())
  }
  list(files = files, registrations = dplyr::bind_rows(registrations))
}

# One repository: its registration outcome and, when usable, its new files.
# Any error reading it becomes a "registration_invalid" row.
read_github_repo <- function(cfg, repo, registered_id, processed, claimed) {
  tryCatch(
    read_github_repo_unsafe(cfg, repo, registered_id, processed, claimed),
    error = function(e) {
      cli::cli_warn("Could not read {.val {repo}}: {conditionMessage(e)}")
      reason <- paste("could not read the repository:", conditionMessage(e))
      list(registration = registration_row(repo, NULL, "registration_invalid", reason),
           claimed = claimed)
    }
  )
}

read_github_repo_unsafe <- function(cfg, repo, registered_id, processed, claimed) {
  settings <- config_get(cfg, "submissions", "github")
  reg <- fetch_registration(cfg, repo, registered_id)
  if (!is.null(reg$invalid)) {
    invalid <- registration_row(repo, reg$invalid$id, "registration_invalid",
                                reg$invalid$reason, sha = reg$invalid$sha)
    return(list(registration = invalid, claimed = claimed))
  }

  claim <- claim_models(reg$parsed$models, repo, claimed)
  registrations <- claim_conflict_rows(repo, reg$info$id, claim$conflicts, reg$model_file$sha)
  if (nrow(claim$models) == 0) {
    return(list(registration = registrations, claimed = claim$claimed))
  }

  plan <- plan_github_files(
    tree = reg$tree, models = claim$models, repo_id = reg$info$id, processed = processed,
    themes = challenge_themes(cfg),
    max_bytes = settings$max_file_mb * 1e6,
    max_files = settings$max_files_per_repo
  )
  plan$repo <- repo
  plan$repo_id <- reg$info$id
  registered <- registration_row(repo, reg$info$id, "registered", "", sha = reg$model_file$sha,
                                 model_ids = claim$models$model_id)
  problems <- reg$parsed$problems
  registered$warnings <- paste(problems$message[problems$severity == "warning"],
                               collapse = "; ")
  list(registration = dplyr::bind_rows(registered, registrations), files = plan,
       claimed = claim$claimed)
}

#' Models described by the registered GitHub repositories
#'
#' Reads the `challenge-model.yaml` of every repository in the registry and
#' returns the models it lists, with the metadata given there. A repository
#' that cannot be read is skipped with a warning, and a model id listed by
#' more than one repository belongs to the first in the registry, as when
#' reading submissions. This is where the model metadata of models submitted
#' from GitHub comes from (see [read_registered_models()]).
#'
#' @inheritParams config_get
#' @param repos The registry. Defaults to [read_forecast_repos()].
#' @return A tibble with the columns of [registration_columns()] (`NA` for
#'   questions not answered), `project_id` set to the challenge's, and `repo`
#'   (`owner/name`).
#' @export
read_github_models <- function(cfg, repos = read_forecast_repos(cfg)) {
  columns <- names(registration_columns(cfg))
  claimed <- character()
  found <- list()
  for (i in seq_len(nrow(repos))) {
    repo <- repos$repo[i]
    reg <- tryCatch(fetch_registration(cfg, repo, repos$repo_id[i]), error = function(e) {
      list(invalid = list(reason = paste("could not read the repository:", conditionMessage(e))))
    })
    if (!is.null(reg$invalid)) {
      cli::cli_warn("Model metadata: skipping {.val {repo}}: {reg$invalid$reason}")
      next
    }
    claim <- claim_models(reg$parsed$models, repo, claimed)
    claimed <- claim$claimed
    if (length(claim$conflicts) > 0) {
      cli::cli_warn(paste0("{.val {repo}} lists {.val {names(claim$conflicts)}}, already ",
                           "registered to another repository; ignored."))
    }
    models <- claim$models
    models$repo <- rep(repo, nrow(models))
    found[[i]] <- models
  }

  models <- dplyr::bind_rows(found)
  if (nrow(models) == 0) models <- empty_models()
  for (col in setdiff(c(columns, "repo"), names(models))) models[[col]] <- NA_character_
  models$project_id <- rep(cfg$project_id, nrow(models))
  dplyr::select(models, dplyr::all_of(c(columns, "repo")))
}
