# Registering a contributor's repository through a GitHub issue.
#
# A contributor opens an issue from the challenge repository's "Register a
# forecast repository" form (label `register-repo`), naming their repository
# (on GitHub, GitLab, Bitbucket or any allowed host) and where their forecasts
# go (the repository or the submissions bucket). The `register` stage runs on
# that issue: it checks the repository the same way the submissions stage will
# read it, and when it is fine adds a row to the registry file in the challenge
# repository, replies on the issue and closes it. Registering by hand, by adding
# the row, remains possible.
#
# The issue text is written by anyone, so it only ever supplies a repository
# address that is matched against a strict pattern and checked against the
# host allowlist, and one of two locations. Everything else is read from the
# repository by the same code the submissions stage uses.
#
# The challenge repository itself is on GitHub: its registry file and issues are
# changed through the GitHub API.

# Token for the GitHub API, if one is set (the Actions token, GITHUB_PAT in the
# workflows).
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

#' Find the repository named in a registration issue
#'
#' The issue form has two fields, "Repository" and "Forecast files". GitHub
#' writes an issue form's answers as `### <label>` headings followed by the
#' answer, which is what this reads. The repository may be `owner/name` (GitHub)
#' or an `https://` address on any host (see [normalize_repo()]); anything else
#' is rejected. The forecast files are in the repository, unless the answer
#' under "Forecast files" mentions the bucket.
#'
#' @param body The issue's text.
#' @return A list with `repo` (`host/owner/name`, or `NA`), `location` (`repo` or
#'   `bucket`) and `error` (why not).
#' @export
#' @examples
#' parse_registration_issue("### Repository\n\nhttps://gitlab.com/alice/forecasts\n")
parse_registration_issue <- function(body) {
  body <- gsub("\r", "", body %||% "")
  lines <- strsplit(body, "\n", fixed = TRUE)[[1]]
  answer_under <- function(label) {
    heading <- which(grepl(paste0("^###\\s+", label, "\\s*$"), lines))
    if (length(heading) != 1) return("")
    rest <- trimws(lines[-seq_len(heading)])
    rest <- rest[nzchar(rest) & !startsWith(rest, "###")]
    if (length(rest) > 0) rest[1] else ""
  }
  repo <- normalize_repo(answer_under("Repository"))
  if (is.na(repo)) {
    return(list(repo = NA_character_, location = NA_character_,
                error = paste("Could not find a repository address like `owner/name` (GitHub) or",
                              "`https://gitlab.com/owner/name` under the Repository heading.")))
  }
  files <- answer_under("Forecast files")
  location <- if (grepl("bucket", files, ignore.case = TRUE)) "bucket" else "repo"
  list(repo = repo, location = location, error = NA_character_)
}

#' Check a repository and register it
#'
#' The checks behind the registration issue. The repository must be public and
#' hold a valid `challenge-model.yaml` for this challenge, and none of its model
#' ids may belong to a repository already in the registry. A model id that is
#' already registered through the registration form is not taken over
#' automatically: a maintainer has to confirm the repository is its owner's.
#'
#' @inheritParams config_get
#' @param repo The repository, `host/owner/name` (see [normalize_repo()]).
#' @param location Where the forecasts go: `repo` or `bucket`.
#' @return A list with `status`, one of `"registered"` (add it to the registry),
#'   `"already_registered"`, `"needs_review"` (valid, but a maintainer must
#'   decide) or `"invalid"`; `message` (Markdown, for the reply); `row` (the
#'   registry row to add, for `"registered"`).
#' @export
check_registration <- function(cfg, repo, location = "repo") {
  reply <- function(status, message, row = NULL) {
    list(status = status, message = message, row = row)
  }
  registry <- read_forecast_repos(cfg)

  reg <- tryCatch(fetch_registration(cfg, repo), error = function(e) {
    list(invalid = list(reason = paste("could not read the repository:", conditionMessage(e))))
  })
  if (!is.null(reg$invalid)) {
    return(reply("invalid", paste0("I could not register `", repo, "`: ", reg$invalid$reason,
                                   ".\n\nFix it and edit this issue to try again.")))
  }
  on.exit(git_close(reg$handle))
  models <- reg$parsed$models$model_id

  if (tolower(repo) %in% tolower(registry$repo)) {
    return(reply("already_registered", paste0("`", repo, "` is already registered.")))
  }

  taken <- read_repo_models(cfg, registry)
  clash <- unique(taken$model_id[taken$model_id %in% models])
  if (length(clash) > 0) {
    other <- unique(taken$repo[taken$model_id %in% clash])
    return(reply("invalid", paste0(
      "I could not register `", repo, "`: the model id", if (length(clash) > 1) "s",
      " ", paste0("`", clash, "`", collapse = ", "), " already belong", if (length(clash) == 1) "s",
      " to ", paste0("`", other, "`", collapse = ", "), ". Choose a different `model_id`."
    )))
  }

  form <- tryCatch(read_sheet_models(cfg)$model_id, error = function(e) character())
  held <- intersect(models, form)
  if (length(held) > 0) {
    return(reply("needs_review", paste0(
      "`", repo, "` is valid, but the model id", if (length(held) > 1) "s", " ",
      paste0("`", held, "`", collapse = ", "), " already ", if (length(held) > 1) "have" else "has",
      " a registration through the registration form. A maintainer will confirm that the ",
      "repository belongs to the model's owner before adding it."
    )))
  }

  row <- tibble::tibble(repo = repo, location = location, registered = format(Sys.Date()))
  results_url <- bucket_uri(cfg, "forecasts_bucket", "submission_results",
                            paste0(models[1], ".csv"), scheme = "https")
  where <- if (location == "bucket") {
    paste0(". Forecasts go to the submissions bucket; this repository is read for the model ",
           "description. ")
  } else {
    paste0(". New forecast files in ",
           paste0("`", unique(reg$parsed$models$path), "`", collapse = ", "),
           " are read every time the challenge processes submissions. ")
  }
  reply("registered", paste0(
    "Registered `", repo, "` for model", if (length(models) > 1) "s", " ",
    paste0("`", models, "`", collapse = ", "), where,
    "What happens to each file is published at ", results_url, "."
  ), row)
}

# Adds a row to the registry CSV in the challenge repository, as a commit on its
# default branch made with the Actions token. The columns are filled by name, so
# the file may order them differently or have more.
commit_registry_row <- function(cfg, row, message) {
  path <- config_get(cfg, "submissions", "repos", "registry")
  if (!is_local_path(path)) {
    cli::cli_abort("The registry {.url {path}} is a URL, so it cannot be updated here.")
  }
  repo <- config_get(cfg, "github_repo")
  contents <- paste0("repos/", repo, "/contents/", path)
  current <- github_request(contents) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  text <- rawToChar(jsonlite::base64_dec(gsub("\n", "", current$content)))
  header <- strsplit(strsplit(text, "\n", fixed = TRUE)[[1]][1], ",", fixed = TRUE)[[1]]
  header <- trimws(header)
  values <- vapply(header, function(col) as.character(row[[col]] %||% ""), character(1))
  if (!endsWith(text, "\n")) text <- paste0(text, "\n")
  updated <- paste0(text, paste(values, collapse = ","), "\n")

  github_request(contents) |>
    httr2::req_method("PUT") |>
    httr2::req_body_json(list(message = message,
                              content = jsonlite::base64_enc(charToRaw(updated)),
                              sha = current$sha)) |>
    httr2::req_perform()
  invisible(TRUE)
}

# Comment on an issue, label it and optionally close it, all with the Actions
# token. A failure here is a warning: the registration itself already happened.
update_issue <- function(cfg, number, comment, labels = character(), close = FALSE) {
  repo <- config_get(cfg, "github_repo")
  post <- function(path, body, method = "POST") {
    github_request(path) |>
      httr2::req_method(method) |>
      httr2::req_body_json(body) |>
      httr2::req_perform()
  }
  tryCatch({
    post(paste0("repos/", repo, "/issues/", number, "/comments"), list(body = comment))
    if (length(labels) > 0) {
      post(paste0("repos/", repo, "/issues/", number, "/labels"), list(labels = as.list(labels)))
    }
    if (close) {
      post(paste0("repos/", repo, "/issues/", number), list(state = "closed"), method = "PATCH")
    }
  }, error = function(e) {
    cli::cli_warn("Could not update issue {number}: {conditionMessage(e)}")
  })
  invisible(TRUE)
}

#' Handle a registration issue
#'
#' The `register` stage. Finds the repository named in the issue
#' ([parse_registration_issue()]), checks it ([check_registration()]) and, when
#' it is fine, adds it to the registry with a commit. Then replies on the issue:
#' a registered repository closes it, one that needs a maintainer is labelled
#' `needs-review`, a problem is explained and labelled `registration-failed`
#' (the contributor can edit the issue to try again). In a dry run nothing is
#' committed or posted; the reply is printed.
#'
#' @inheritParams config_get
#' @param body The issue's text.
#' @param number The issue's number.
#' @return The result of [check_registration()] (or a failure to find a
#'   repository), invisibly.
#' @export
run_registration <- function(cfg, body, number) {
  if (!repos_enabled(cfg)) {
    cli::cli_abort("Set {.field submissions$repos$registry} before registering repositories.")
  }
  found <- parse_registration_issue(body)
  result <- if (is.na(found$repo)) {
    list(status = "invalid", message = found$error)
  } else {
    log_step("Registering {found$repo}")
    check_registration(cfg, found$repo, found$location)
  }

  if (result$status == "registered" && !is_dry_run()) {
    commit_message <- paste0("Register ", found$repo, " (issue #", number, ")")
    tryCatch(commit_registry_row(cfg, result$row, commit_message), error = function(e) {
      result$status <<- "needs_review"
      result$message <<- paste0(
        "`", found$repo, "` is valid, but I could not add it to the registry (",
        conditionMessage(e), "). A maintainer will add it."
      )
    })
  }

  cli::cli_inform(c("i" = "{result$status}: {result$message}"))
  if (is_dry_run()) {
    cli::cli_inform("DRY RUN: no commit and no reply on the issue.")
  } else {
    update_issue(
      cfg, number, result$message,
      labels = switch(result$status, registered = "registered", needs_review = "needs-review",
                      invalid = "registration-failed", character()),
      close = result$status %in% c("registered", "already_registered")
    )
  }
  invisible(result)
}
