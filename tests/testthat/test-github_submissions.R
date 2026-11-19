test_that("a valid challenge-model.yaml gives its models and metadata", {
  text <- model_yaml("    long_name: My model\n    description: Does things\n",
                     "  - model_id: other_model\n    path: ./out\n")
  parsed <- parse_challenge_model(text, test_config())
  expect_equal(parsed$models$model_id, c("my-model", "other_model"))
  expect_equal(parsed$models$path, c("forecasts/", "out/"))
  expect_equal(parsed$models$long_name[1], "My model")
  expect_false(any(parsed$problems$severity == "error"))
})

test_that("a file can hold a block for each challenge", {
  text <- paste0("- challenge: other\n  models: [{model_id: a}]\n",
                 "- challenge: testcast\n  models: [{model_id: b}]\n")
  expect_equal(parse_challenge_model(text, test_config())$models$model_id, "b")
})

test_that("problems in challenge-model.yaml are errors or warnings", {
  cfg <- test_config()
  errors <- function(text) {
    p <- parse_challenge_model(text, cfg)
    expect_equal(nrow(p$models), 0)
    p$problems$message[p$problems$severity == "error"]
  }
  expect_match(errors("a: [unclosed"), "not valid YAML")
  expect_match(errors("just text"), "mapping")
  expect_match(errors("challenge: other\nmodels: [{model_id: a}]"), "testcast")
  expect_match(errors("challenge: testcast\nmodels: []"), "at least one")
  expect_match(errors("challenge: testcast\nmodels: [{model_id: 'a b'}]"), "model_id")
  expect_match(errors("challenge: testcast\nmodels: [{model_id: a, path: ../x}]"), "path")
  expect_match(errors("challenge: testcast\nmodels: [{model_id: a}, {model_id: a}]"), "twice")
  expect_match(errors(model_yaml("    description: [a, b]\n")), "single value")

  warn <- parse_challenge_model(model_yaml("    colour: red\n"), cfg)$problems
  expect_true(all(warn$severity == "warning"))
  expect_match(paste(warn$message, collapse = " "), "unknown key colour")
  expect_match(paste(warn$message, collapse = " "), "long_name")
})

test_that("YAML is never evaluated", {
  text <- model_yaml("    long_name: !expr stop('evaluated')\n")
  expect_no_error(parse_challenge_model(text, test_config()))
})

test_that("the registry is read, and bad rows dropped", {
  path <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("repo,repo_id,registered", "alice/forecasts,1,2026-01-01",
               "not a repo,,", "bob/x,,"), path)
  cfg <- test_config()
  cfg$submissions$github$registry <- path
  expect_warning(repos <- read_forecast_repos(cfg), "owner/name")
  expect_equal(repos$repo, c("alice/forecasts", "bob/x"))
  expect_equal(repos$repo_id, c("1", NA))

  writeLines(c("repo", "alice/forecasts", "ALICE/forecasts"), path)
  expect_warning(repos <- read_forecast_repos(cfg), "twice")
  expect_equal(repos$repo, "alice/forecasts")

  cfg$submissions$github$registry <- "missing.csv"
  expect_error(read_forecast_repos(cfg), "does not exist")
})

test_that("plan_github_files() applies the registration rules", {
  models <- tibble::tibble(model_id = "my-model", path = "forecasts/")
  plan <- plan_github_files(
    tree_fixture(), models, repo_id = "7",
    processed = "github/7/forecasts/lakes-2026-01-02-my-model.csv.gz",
    themes = c("lakes", "birds"), max_bytes = 100e6)

  by_path <- function(p) plan[plan$path == p, ]
  expect_equal(by_path("forecasts/lakes-2026-01-01-my-model.csv.gz")$action, "download")
  expect_equal(by_path("forecasts/lakes-2026-01-01-my-model.csv.gz")$key,
               "github/7/forecasts/lakes-2026-01-01-my-model.csv.gz")
  # Already processed, other challenges' themes, other folders and non-forecast
  # files are left out without a word.
  expect_false("forecasts/lakes-2026-01-02-my-model.csv.gz" %in% plan$path)
  expect_false("forecasts/other-2026-01-03-my-model.csv" %in% plan$path)
  expect_false("elsewhere/lakes-2026-01-01-my-model.csv" %in% plan$path)
  expect_false("README.md" %in% plan$path)
  # Reported to the submitter.
  other <- by_path("forecasts/lakes-2026-01-03-other-model.csv")
  expect_equal(other$action, "skip")
  expect_match(other$reason, "not listed")
  # The repository's only model owns a badly named file.
  notes <- by_path("forecasts/notes.csv")
  expect_equal(c(notes$action, notes$model_id), c("skip", "my-model"))
  expect_match(notes$reason, "name is not")
  expect_match(by_path("forecasts/lakes-2026-01-04-my-model.csv")$reason, "larger than 100 MB")
  expect_equal(by_path("forecasts/birds-2026-01-03-my-model.csv")$action, "download")
})

test_that("plan_github_files() caps the files per run, oldest names first", {
  models <- tibble::tibble(model_id = "my-model", path = "forecasts/")
  plan <- plan_github_files(tree_fixture(), models, "7", max_files = 1,
                            themes = "lakes")
  expect_equal(sum(plan$action == "download"), 1)
  expect_equal(plan$path[plan$action == "download"],
               "forecasts/lakes-2026-01-01-my-model.csv.gz")
})

test_that("a model may be listed for the repository root", {
  models <- tibble::tibble(model_id = "m", path = "")
  tree <- tibble::tibble(path = "lakes-2026-01-01-m.csv", type = "blob",
                         sha = "s", size = 1)
  expect_equal(plan_github_files(tree, models, "7")$action, "download")
})

test_that("list_github_submissions() reads each registered repository", {
  mock_github()
  repos <- tibble::tibble(repo = c("alice/forecasts", "gone/repo"),
                          repo_id = c("7", NA), registered = NA_character_)
  out <- suppressWarnings(
    list_github_submissions(github_cfg(), character(), repos = repos)
  )
  expect_equal(unique(out$files$repo), "alice/forecasts")
  expect_equal(unique(out$files$repo_id), "7")
  expect_true(any(out$files$action == "download"))

  reg <- out$registrations
  expect_equal(reg$status, c("registered", "registration_invalid"))
  expect_equal(reg$results_name, c("my-model", "github_gone_repo"))
  expect_match(reg$reason[2], "could not read the repository")
})

test_that("a private repository, a changed id or a missing file is not read", {
  repos <- tibble::tibble(repo = "alice/forecasts", repo_id = "7", registered = NA_character_)
  run <- function() list_github_submissions(github_cfg(), character(), repos = repos)

  mock_github(private = TRUE)
  out <- run()
  expect_match(out$registrations$reason, "private")
  expect_equal(nrow(out$files), 0)

  mock_github(id = "99")
  expect_match(run()$registrations$reason, "id differs")

  mock_github(yaml = "challenge: other\nmodels: [{model_id: a}]")
  out <- run()
  expect_match(out$registrations$reason, "testcast")
  expect_equal(nrow(out$files), 0)
})

test_that("GitHub submissions are processed and reported alongside others", {
  skip_if_not_installed("score4cast")
  skip_if_not_installed("arrow")
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  mock_github()
  fc <- example_forecast()
  testthat::local_mocked_bindings(
    github_blob = function(repo, sha, dest) {
      readr::write_csv(fc, dest)
      invisible(dest)
    },
    read_published_results = function(remote) {
      tibble::tibble(model_id = character(), file = character(), source = character(),
                     sha = character(), first_seen = character(), status = character(),
                     reason = character(), warnings = character())
    }
  )
  repos <- tibble::tibble(repo = "alice/forecasts", repo_id = "7", registered = NA_character_)
  testthat::local_mocked_bindings(read_forecast_repos = function(cfg) repos)

  state <- list(processed = character(), work_dir = withr::local_tempdir(),
                time_stamp = "20260101000000")
  out <- suppressMessages(process_github_submissions(github_cfg(), state))

  res <- out$results
  expect_equal(sum(res$status == "processed"), 3)
  expect_true(all(res$source[res$status == "processed"] == "github:alice/forecasts"))
  expect_true(all(c("registered", "skipped") %in% res$status))
  # Processed files are in the record, skipped ones are not.
  expect_equal(sort(out$processed),
               sort(paste0("github/7/", res$file[res$status == "processed"])))
  # The raw copy and parquet were written (to the dry-run folder).
  expect_gt(length(list.files(dry_run_dir(), recursive = TRUE)), 0)
})

test_that("booleans in challenge-model.yaml become the form's answers", {
  text <- model_yaml("    dynamic: true\n    uses_drivers: no\n    model_type: empirical\n")
  models <- parse_challenge_model(text, test_config())$models
  expect_equal(c(models$dynamic, models$uses_drivers, models$model_type),
               c("Yes", "No", "empirical"))
})

two_repos <- function() {
  tibble::tibble(repo = c("alice/first", "bob/second"), repo_id = c("1", "2"),
                 registered = NA_character_)
}

# Each repository lists my-model; bob's also lists his own.
mock_two_repos <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    github_repo_info = function(repo) {
      list(id = c("alice/first" = "1", "bob/second" = "2")[[repo]], full_name = repo,
           default_branch = "main", private = FALSE)
    },
    github_tree = function(repo, branch) tree_fixture(),
    github_text = function(repo, sha) {
      if (repo == "alice/first") {
        model_yaml("    long_name: Alice's model\n    dynamic: true\n")
      } else {
        paste0(model_yaml("    long_name: Bob's copy\n"), "  - model_id: bobs-model\n")
      }
    },
    .env = env
  )
}

test_that("a model id belongs to the first repository that lists it", {
  mock_two_repos()
  out <- suppressWarnings(list_github_submissions(github_cfg(), character(), repos = two_repos()))
  # Only the first repository's files are read for my-model.
  mine <- out$files[out$files$model_id == "my-model" & out$files$action == "download", ]
  expect_equal(unique(mine$repo), "alice/first")
  reg <- out$registrations
  expect_match(reg$reason[reg$status == "registration_invalid"],
               "my-model is already registered to alice/first")
  expect_equal(reg$results_name[reg$status == "registration_invalid"], "github_2")
})

test_that("model metadata is read from the repositories", {
  mock_two_repos()
  models <- suppressWarnings(read_github_models(github_cfg(), two_repos()))
  expect_equal(models$model_id, c("my-model", "bobs-model"))
  expect_equal(models$repo, c("alice/first", "bob/second"))
  expect_equal(models$long_name[1], "Alice's model")
  expect_equal(models$dynamic[1], "Yes")
  expect_equal(unique(models$project_id), "testcast")
  expect_true(all(names(registration_columns(test_config())) %in% names(models)))
})

sheet_fixture <- function(cfg) {
  columns <- registration_columns(cfg)
  sheet <- tibble::as_tibble(rlang::set_names(rep(list(NA_character_), length(columns)), columns))
  sheet <- sheet[rep(1, 3), ]
  sheet[[columns[["model_id"]]]] <- c("my-model", "form-only", "example-x")
  sheet[[columns[["project_id"]]]] <- "testcast"
  sheet[[columns[["long_name"]]]] <- c("Form name", "Form only", "Ex")
  sheet[[columns[["description"]]]] <- c("Form description", "Only in the form", NA)
  sheet
}

test_that("registered models combine the form and the repositories' files", {
  mock_two_repos()
  cfg <- github_cfg()
  github <- suppressWarnings(read_github_models(cfg, two_repos()))
  models <- read_registered_models(cfg, sheet = sheet_fixture(cfg), github = github)
  expect_equal(models$model_id, c("bobs-model", "form-only", "my-model"))
  mine <- models[models$model_id == "my-model", ]
  # The file wins where it answers, the form fills the rest.
  expect_equal(c(mine$long_name, mine$description, mine$dynamic),
               c("Alice's model", "Form description", "Yes"))
  expect_equal(models$description[models$model_id == "form-only"], "Only in the form")
  # Bob's own model has no answers; his claim on my-model changed nothing.
  expect_true(is.na(models$long_name[models$model_id == "bobs-model"]))
})

test_that("without GitHub, registered models are the form's, as before", {
  cfg <- test_config()
  models <- read_registered_models(cfg, sheet = sheet_fixture(cfg))
  expect_equal(models$model_id, c("form-only", "my-model"))
})

test_that("a GitHub-only challenge needs no registration sheet", {
  mock_two_repos()
  cfg <- github_cfg()
  cfg$model_metadata_gsheet <- NULL
  github <- suppressWarnings(read_github_models(cfg, two_repos()))
  models <- read_registered_models(cfg, github = github)
  expect_equal(models$model_id, c("bobs-model", "my-model"))
})
