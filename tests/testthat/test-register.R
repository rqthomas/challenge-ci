form_body <- function(repo, files = NULL) {
  paste0("### Repository\n\n", repo, "\n\n",
         if (!is.null(files)) paste0("### Forecast files\n\n", files, "\n\n"),
         "### Notes\n\n_No response_\n")
}

test_that("the repository is read from the issue form's answer", {
  repo <- function(body) parse_registration_issue(body)$repo
  expect_equal(repo(form_body("alice/forecasts")), "github.com/alice/forecasts")
  expect_equal(repo(form_body("https://github.com/alice/forecasts")), "github.com/alice/forecasts")
  expect_equal(repo(form_body("https://github.com/alice/forecasts.git/")),
               "github.com/alice/forecasts")
  expect_equal(repo(form_body("https://gitlab.com/team/sub/model")), "gitlab.com/team/sub/model")
  expect_equal(repo(form_body("https://bitbucket.org/ws/repo.git")), "bitbucket.org/ws/repo")
  expect_equal(repo(gsub("\n", "\r\n", form_body("alice/my.repo_2"))), "github.com/alice/my.repo_2")

  for (bad in c("", "alice", "http://github.com/alice/x", "a b/c", "ssh://git@github.com/a/b",
                "https://user:pw@github.com/a/b", "alice/forecasts; rm -rf /", "$(whoami)/x")) {
    expect_true(is.na(repo(form_body(bad))), info = bad)
  }
  expect_true(is.na(repo("no headings here: alice/forecasts")))
  expect_match(parse_registration_issue("")$error, "owner/name")
  # Only a Repository heading counts, once.
  expect_true(is.na(repo("### Repository\n\na/b\n### Repository\n\nc/d")))
})

test_that("the forecast location is read from the form, repository by default", {
  location <- function(body) parse_registration_issue(body)$location
  expect_equal(location(form_body("alice/x")), "repo")
  expect_equal(location(form_body("alice/x", "In my repository")), "repo")
  expect_equal(location(form_body("alice/x", "In the submissions bucket")), "bucket")
  expect_equal(location(form_body("alice/x", "Bucket")), "bucket")
})

registry_cfg <- function() {
  cfg <- github_cfg()
  cfg$github_repo <- "owner/challenge"
  cfg
}

stub_registration <- function(registry = tibble::tibble(repo = character(), location = character(),
                                                        registered = character()),
                              taken = NULL, form = character(), env = parent.frame()) {
  taken <- taken %||% tibble::tibble(model_id = character(), repo = character())
  testthat::local_mocked_bindings(
    read_forecast_repos = function(cfg) registry,
    read_repo_models = function(cfg, repos) taken,
    read_sheet_models = function(cfg, sheet = NULL) tibble::tibble(model_id = form),
    .env = env
  )
}

test_that("a valid new repository is registered", {
  mock_git()
  stub_registration()
  res <- check_registration(registry_cfg(), "github.com/alice/forecasts")
  expect_equal(res$status, "registered")
  expect_equal(res$row$repo, "github.com/alice/forecasts")
  expect_equal(res$row$location, "repo")
  expect_match(res$message, "my-model")
  expect_match(res$message, "forecasts/")
  expect_match(res$message, "submission_results/my-model.csv")
})

test_that("a repository for the bucket says where forecasts go", {
  mock_git()
  stub_registration()
  res <- check_registration(registry_cfg(), "gitlab.com/alice/forecasts", "bucket")
  expect_equal(res$status, "registered")
  expect_equal(res$row$location, "bucket")
  expect_match(res$message, "submissions bucket")
})

test_that("a repository can be registered once", {
  mock_git()
  stub_registration(tibble::tibble(repo = "GitHub.com/Alice/Forecasts", location = "repo",
                                   registered = "2026-01-01"))
  expect_equal(check_registration(registry_cfg(), "github.com/alice/forecasts")$status,
               "already_registered")
})

test_that("a model id of another repository is refused", {
  mock_git()
  stub_registration(taken = tibble::tibble(model_id = "my-model", repo = "github.com/bob/other"))
  res <- check_registration(registry_cfg(), "github.com/alice/forecasts")
  expect_equal(res$status, "invalid")
  expect_match(res$message, "belongs? to `github.com/bob/other`")
})

test_that("a model id already registered through the form needs a maintainer", {
  mock_git()
  stub_registration(form = c("my-model", "another"))
  res <- check_registration(registry_cfg(), "github.com/alice/forecasts")
  expect_equal(res$status, "needs_review")
  expect_match(res$message, "maintainer")
})

test_that("an unusable repository is explained", {
  stub_registration()
  res <- check_registration(registry_cfg(), "github.com/gone/repo")
  expect_equal(res$status, "invalid")
  expect_match(res$message, "private, missing or unreachable")

  mock_git(yaml = "challenge: other\nmodels: [{model_id: a}]")
  expect_match(check_registration(registry_cfg(), "github.com/alice/forecasts")$message, "testcast")

  res <- check_registration(registry_cfg(), "evil.example/alice/forecasts")
  expect_match(res$message, "not an allowed git host")
})

test_that("the registry row is added by column name, with the Actions token", {
  existing <- "registered,repo,location,note\n2026-01-01,github.com/old/x,repo,hi"
  put <- NULL
  httr2::local_mocked_responses(function(req) {
    if (identical(req$method, "PUT")) {
      put <<- req
      return(httr2::response_json(body = list(ok = TRUE)))
    }
    httr2::response_json(body = list(content = jsonlite::base64_enc(charToRaw(existing)),
                                     sha = "abc123"))
  })
  row <- tibble::tibble(repo = "github.com/alice/forecasts", location = "bucket",
                        registered = "2026-11-19")
  commit_registry_row(registry_cfg(), row, "Register alice/forecasts")

  body <- put$body$data
  expect_equal(body$sha, "abc123")
  expect_equal(body$message, "Register alice/forecasts")
  written <- rawToChar(jsonlite::base64_dec(body$content))
  expect_equal(written, paste0(existing, "\n2026-11-19,github.com/alice/forecasts,bucket,\n"))
  expect_match(put$url, "repos/owner/challenge/contents/unused.csv")
})

test_that("a registry that is a URL cannot be committed to", {
  cfg <- registry_cfg()
  cfg$submissions$repos$registry <- "https://example.org/repos.csv"
  expect_error(commit_registry_row(cfg, tibble::tibble(repo = "a/b"), "m"), "URL")
})

issue_body <- "### Repository\n\nalice/forecasts\n"

test_that("a registered repository is committed, then the issue answered and closed", {
  committed <- NULL
  posted <- NULL
  checked <- NULL
  testthat::local_mocked_bindings(
    check_registration = function(cfg, repo, location = "repo") {
      checked <<- c(repo, location)
      list(status = "registered", message = "done",
           row = tibble::tibble(repo = repo, location = location, registered = "2026-11-19"))
    },
    commit_registry_row = function(cfg, row, message) committed <<- list(row, message),
    update_issue = function(cfg, number, comment, labels = character(), close = FALSE) {
      posted <<- list(number, comment, labels, close)
    }
  )
  res <- suppressMessages(run_registration(registry_cfg(), issue_body, "12"))
  expect_equal(res$status, "registered")
  expect_equal(checked, c("github.com/alice/forecasts", "repo"))
  expect_equal(committed[[1]]$repo, "github.com/alice/forecasts")
  expect_match(committed[[2]], "issue #12")
  expect_equal(posted, list("12", "done", "registered", TRUE))
})

test_that("a failed commit leaves the issue open for a maintainer", {
  posted <- NULL
  testthat::local_mocked_bindings(
    check_registration = function(cfg, repo, location = "repo") {
      list(status = "registered", message = "done", row = tibble::tibble(repo = repo))
    },
    commit_registry_row = function(cfg, row, message) stop("409 conflict"),
    update_issue = function(cfg, number, comment, labels = character(), close = FALSE) {
      posted <<- list(comment, labels, close)
    }
  )
  suppressMessages(run_registration(registry_cfg(), issue_body, "12"))
  expect_match(posted[[1]], "409 conflict")
  expect_equal(posted[[2]], "needs-review")
  expect_false(posted[[3]])
})

test_that("an issue without a usable repository is answered, not failed", {
  posted <- NULL
  testthat::local_mocked_bindings(
    update_issue = function(cfg, number, comment, labels = character(), close = FALSE) {
      posted <<- list(comment, labels, close)
    }
  )
  res <- suppressMessages(run_registration(registry_cfg(), "nothing useful", "3"))
  expect_equal(res$status, "invalid")
  expect_equal(posted[[2]], "registration-failed")
  expect_false(posted[[3]])
})

test_that("a dry run commits and posts nothing", {
  withr::local_envvar(DRY_RUN = "true")
  testthat::local_mocked_bindings(
    check_registration = function(cfg, repo, location = "repo") {
      list(status = "registered", message = "done", row = tibble::tibble(repo = repo))
    },
    commit_registry_row = function(...) stop("must not commit"),
    update_issue = function(...) stop("must not post")
  )
  expect_message(run_registration(registry_cfg(), issue_body, "12"), "DRY RUN")
})

test_that("registration needs the repository source to be on", {
  expect_error(run_registration(test_config(), issue_body, "1"), "submissions\\$repos\\$registry")
})
