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

test_that("booleans in challenge-model.yaml become the form's answers", {
  text <- model_yaml("    dynamic: true\n    uses_drivers: no\n    model_type: empirical\n")
  models <- parse_challenge_model(text, test_config())$models
  expect_equal(c(models$dynamic, models$uses_drivers, models$model_type),
               c("Yes", "No", "empirical"))
})

test_that("the registry is read: addresses normalised, locations checked", {
  path <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("repo,location,registered",
               "alice/forecasts,,2026-01-01",
               "https://GitLab.com/team/sub/model.git/,bucket,",
               "not a repo,,",
               "ssh://git@github.com/a/b,,",
               "bob/x,somewhere,"), path)
  cfg <- test_config()
  cfg$submissions$repos$registry <- path
  expect_warning(
    expect_warning(repos <- read_forecast_repos(cfg), "not repository addresses"),
    "location"
  )
  expect_equal(repos$repo, c("github.com/alice/forecasts", "gitlab.com/team/sub/model"))
  expect_equal(repos$location, c("repo", "bucket"))

  # A registry without a location column is all repositories.
  writeLines(c("repo", "alice/forecasts", "ALICE/forecasts"), path)
  expect_warning(repos <- read_forecast_repos(cfg), "twice")
  expect_equal(repos$repo, "github.com/alice/forecasts")
  expect_equal(repos$location, "repo")

  cfg$submissions$repos$registry <- "missing.csv"
  expect_error(read_forecast_repos(cfg), "does not exist")
})

test_that("plan_repo_files() picks new forecast files in the model's folder", {
  models <- tibble::tibble(model_id = "my-model", path = "forecasts/")
  repo <- "github.com/alice/forecasts"
  plan <- plan_repo_files(tree_fixture(), models, repo,
                          blocked = paste0(repo, "/forecasts/2026-01-02.csv.gz"))
  # Names are free-form; only the folder and the extension matter.
  expect_equal(plan$path, c("forecasts/2026-01-01.csv.gz", "forecasts/anything.csv"))
  expect_equal(plan$key[1], paste0(repo, "/forecasts/2026-01-01.csv.gz"))
  expect_equal(plan$model_id, c("my-model", "my-model"))
  expect_equal(plan$allowed[[1]], "my-model")
})

test_that("a file whose key and SHA are held is left out, an edited one is not", {
  models <- tibble::tibble(model_id = "m", path = "forecasts/")
  repo <- "github.com/a/b"
  key <- paste0(repo, "/forecasts/anything.csv")
  edited <- plan_repo_files(tree_fixture(), models, repo,
                            blocked = paste0(key, "@some-older-sha"))
  expect_true("forecasts/anything.csv" %in% edited$path)
  held <- plan_repo_files(tree_fixture(), models, repo,
                          blocked = paste0(key, "@sha-forecasts/anything.csv"))
  expect_false("forecasts/anything.csv" %in% held$path)
})

test_that("a shared folder leaves the model to the file, and files are capped", {
  models <- tibble::tibble(model_id = c("a", "b"), path = c("forecasts/", "forecasts/"))
  plan <- plan_repo_files(tree_fixture(), models, "github.com/a/b", max_files = 2)
  expect_true(all(is.na(plan$model_id)))
  expect_equal(plan$allowed[[1]], c("a", "b"))
  expect_equal(nrow(plan), 2)

  root <- tibble::tibble(model_id = "m", path = "")
  tree <- tibble::tibble(path = "x.csv", type = "blob", sha = "s", size = NA_real_)
  expect_equal(plan_repo_files(tree, root, "github.com/a/b")$model_id, "m")
})

test_that("load_registry() reads each repository and reports the outcome", {
  mock_git()
  repos <- dplyr::bind_rows(repo_row("github.com/alice/forecasts"),
                            repo_row("github.com/gone/repo"),
                            repo_row("gitlab.com/bob/model", "bucket"))
  expect_warning(registry <- load_registry(github_cfg(), repos), "gone/repo")
  withr::defer(close_registry(registry))

  reg <- registry$registrations
  expect_equal(reg$status[reg$source == "github.com/gone/repo"], "registration_invalid")
  expect_match(reg$reason[reg$source == "github.com/gone/repo"], "could not read the repository")
  expect_equal(reg$results_name[reg$source == "github.com/gone/repo"],
               "repo_github.com_gone_repo")
  # my-model belongs to the first repository that lists it.
  expect_equal(registry$models$model_id, "my-model")
  expect_equal(registry$models$repo, "github.com/alice/forecasts")
  expect_match(reg$reason[reg$source == "gitlab.com/bob/model"], "my-model is already registered")
  # Only repositories whose files are read keep a clone.
  expect_equal(names(registry$entries), "github.com/alice/forecasts")
})

test_that("a repository for the bucket is read for its models only", {
  mock_git()
  registry <- load_registry(github_cfg(), repo_row("github.com/alice/forecasts", "bucket"))
  expect_equal(registry$models$location, "bucket")
  expect_length(registry$entries, 0)
  expect_match(registry$registrations$reason, "submissions bucket")
})

test_that("a repository with no usable challenge-model.yaml is not read", {
  repos <- repo_row("github.com/alice/forecasts")
  mock_git(yaml = "challenge: other\nmodels: [{model_id: a}]")
  registry <- load_registry(github_cfg(), repos)
  expect_match(registry$registrations$reason, "testcast")
  expect_equal(nrow(registry$models), 0)

  testthat::local_mocked_bindings(
    git_tree = function(handle) tree_fixture()[-1, ]
  )
  registry <- load_registry(github_cfg(), repos)
  expect_match(registry$registrations$reason, "no challenge-model.yaml")
})

test_that("a host that is not allowed is not cloned", {
  cfg <- github_cfg()
  expect_equal(repo_clone_url(cfg, "gitlab.com/a/b"), "https://gitlab.com/a/b.git")
  expect_error(repo_clone_url(cfg, "evil.example/a/b"), "not an allowed git host")
  cfg$submissions$repos$allowed_hosts <- c(cfg$submissions$repos$allowed_hosts, "git.example.org")
  expect_equal(repo_clone_url(cfg, "git.example.org/a/b"), "https://git.example.org/a/b.git")
})

test_that("repository addresses are normalised and bad ones refused", {
  expect_equal(
    normalize_repo(c("alice/forecasts", "https://github.com/alice/forecasts.git/",
                     "HTTPS://GitLab.com/Team/sub/model", "bitbucket.org/ws/repo",
                     "https://codeberg.org/a/b/")),
    c("github.com/alice/forecasts", "github.com/alice/forecasts",
      "gitlab.com/Team/sub/model", "bitbucket.org/ws/repo", "codeberg.org/a/b")
  )
  for (bad in c("", "alice", "http://github.com/a/b", "ssh://git@github.com/a/b",
                "git@github.com:a/b.git", "https://user:pw@github.com/a/b",
                "https://github.com:8080/a/b", "https://github.com/a/b?x=1",
                "https://github.com/a/../b", "a b/c", "alice/forecasts; rm -rf /",
                "$(whoami)/x", "-evil/x", "file:///etc/passwd")) {
    expect_true(is.na(normalize_repo(bad)), info = bad)
  }
})

test_that("list_repo_submissions() lists new files of the repositories read", {
  mock_git()
  repos <- dplyr::bind_rows(repo_row("github.com/alice/forecasts"),
                            repo_row("github.com/bob/other", "bucket"))
  registry <- load_registry(github_cfg(), repos)
  withr::defer(close_registry(registry))
  out <- list_repo_submissions(github_cfg(), character(), registry)
  expect_equal(unique(out$files$repo), "github.com/alice/forecasts")
  expect_equal(nrow(out$files), 3)
  expect_identical(out$registrations, registry$registrations)
})

test_that("repository submissions are processed, recorded and reported", {
  skip_if_not_installed("score4cast")
  skip_if_not_installed("arrow")
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  mock_git()
  testthat::local_mocked_bindings(
    git_blob = function(handle, sha, dest, timeout = 300, max_bytes = Inf) {
      day <- c("sha-forecasts/2026-01-01.csv.gz" = 0, "sha-forecasts/2026-01-02.csv.gz" = 1,
               "sha-forecasts/anything.csv" = 2)[[sha]]
      readr::write_csv(forecast_on(day), dest)
      invisible(dest)
    },
    read_published_results = function(remote) {
      tibble::as_tibble(rlang::set_names(rep(list(character()), length(published_columns)),
                                         published_columns))
    }
  )
  cfg <- github_cfg()
  registry <- load_registry(cfg, repo_row("github.com/alice/forecasts"))
  withr::defer(close_registry(registry))
  state <- new_state(registry)

  res <- suppressMessages(process_repo_submissions(cfg, state))
  expect_equal(sum(res$status == "processed"), 3)
  expect_true(all(res$source == "github.com/alice/forecasts"))
  expect_true(all(res$model_id == "my-model"))
  expect_equal(res$rows_kept, rep(12L, 3))
  # They are all in the record, by key, and their units are remembered.
  expect_equal(sort(state$record$key),
               paste0("github.com/alice/forecasts/", sort(res$file)))
  expect_equal(unique(state$record$status), "processed")
  expect_equal(length(ls(state$units$set)), 3)
  # The record and the units were written (to the dry-run folder), once.
  expect_gt(length(list.files(dry_run_dir(), recursive = TRUE)), 0)
  expect_equal(state$pending, 0L)

  # Nothing is new the next time.
  again <- list_repo_submissions(cfg, manifest_tokens(state$record), registry)
  expect_equal(nrow(again$files), 0)
})

two_repos <- function() {
  dplyr::bind_rows(repo_row("github.com/alice/first"), repo_row("gitlab.com/bob/second"))
}

# Each repository lists my-model; bob's also lists his own. The clone's commit
# tells the repositories apart.
mock_two_repos <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    git_open = function(url, timeout = 120) {
      list(dir = NULL, branch = "main", commit = if (grepl("alice", url)) "alice" else "bob")
    },
    git_tree = function(handle) tree_fixture(),
    git_text = function(handle, sha, max_bytes = 1e6) {
      if (handle$commit == "alice") {
        model_yaml("    long_name: Alice's model\n    dynamic: true\n")
      } else {
        paste0(model_yaml("    long_name: Bob's copy\n"), "  - model_id: bobs-model\n")
      }
    },
    .env = env
  )
}

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

test_that("model metadata is read from the repositories", {
  mock_two_repos()
  models <- suppressWarnings(read_repo_models(github_cfg(), two_repos()))
  expect_equal(models$model_id, c("my-model", "bobs-model"))
  expect_equal(models$repo, c("github.com/alice/first", "gitlab.com/bob/second"))
  expect_equal(models$long_name[1], "Alice's model")
  expect_equal(models$dynamic[1], "Yes")
  expect_equal(unique(models$project_id), "testcast")
  expect_true(all(names(registration_columns(test_config())) %in% names(models)))
})

test_that("registered models combine the form and the repositories' files", {
  mock_two_repos()
  cfg <- github_cfg()
  github <- suppressWarnings(read_repo_models(cfg, two_repos()))
  models <- read_registered_models(cfg, sheet = sheet_fixture(cfg), github = github)
  # (The challenge's own baselines are registered too; see test-registrations.R.)
  models <- models[!models$baseline, ]
  expect_equal(models$model_id, c("bobs-model", "form-only", "my-model"))
  mine <- models[models$model_id == "my-model", ]
  # The file wins where it answers, the form fills the rest.
  expect_equal(c(mine$long_name, mine$description, mine$dynamic),
               c("Alice's model", "Form description", "Yes"))
  expect_equal(models$description[models$model_id == "form-only"], "Only in the form")
  # Bob's own model has no answers; his claim on my-model changed nothing.
  expect_true(is.na(models$long_name[models$model_id == "bobs-model"]))
})

test_that("without repositories, registered models are the form's, as before", {
  cfg <- test_config()
  models <- read_registered_models(cfg, sheet = sheet_fixture(cfg))
  expect_equal(models$model_id[!models$baseline], c("form-only", "my-model"))
})

test_that("a repositories-only challenge needs no registration sheet", {
  mock_two_repos()
  cfg <- github_cfg()
  cfg$model_metadata_gsheet <- NULL
  github <- suppressWarnings(read_repo_models(cfg, two_repos()))
  models <- read_registered_models(cfg, github = github)
  expect_equal(models$model_id[!models$baseline], c("bobs-model", "my-model"))
})

test_that("git reads a real repository: files by SHA, no checkout, no sizes", {
  skip_if(!nzchar(Sys.which("git")), "git is not installed")
  src <- withr::local_tempdir()
  git <- function(...) system2("git", c("-C", src, "-c", "user.name=t", "-c", "user.email=t@t", ...),
                               stdout = FALSE, stderr = FALSE)
  git("init", "-q", "-b", "main")
  git("config", "uploadpack.allowFilter", "true")
  git("config", "uploadpack.allowAnySHA1InWant", "true")
  dir.create(file.path(src, "forecasts"))
  writeLines("challenge: testcast", file.path(src, "challenge-model.yaml"))
  writeLines(c("a,b", "1,2"), file.path(src, "forecasts", "x.csv"))
  git("add", ".")
  git("commit", "-q", "-m", "first")

  withr::local_options(challengeci.git_protocols = c("https", "file"))
  handle <- git_open(paste0("file://", src))
  withr::defer(git_close(handle))
  expect_equal(handle$branch, "main")
  tree <- git_tree(handle)
  expect_setequal(tree$path, c("challenge-model.yaml", "forecasts/x.csv"))
  expect_true(all(is.na(tree$size)))
  # No working tree was checked out.
  expect_false(file.exists(file.path(handle$dir, "forecasts")))
  dest <- withr::local_tempfile()
  git_blob(handle, tree$sha[tree$path == "forecasts/x.csv"], dest)
  expect_equal(readLines(dest), c("a,b", "1,2"))
  expect_equal(git_text(handle, tree$sha[tree$path == "challenge-model.yaml"]),
               "challenge: testcast")
  expect_error(git_blob(handle, "not-a-sha", dest))
  # A repository that cannot be cloned is an error with the reason.
  expect_error(git_open(paste0("file://", file.path(src, "nothing"))), "could not be cloned")
  # Without the protocol allowed, nothing is cloned.
  withr::local_options(challengeci.git_protocols = "https")
  expect_error(git_open(paste0("file://", src)), "could not be cloned")
})

test_that("a challenge-model.yaml is drafted from the form's answers", {
  cfg <- test_config()
  sheet <- sheet_fixture(cfg)
  columns <- registration_columns(cfg)
  sheet[[columns[["dynamic"]]]] <- c("Yes", "No", NA)
  sheet[[columns[["uses_drivers"]]]] <- c("Yes and at least one is estimated from data", NA, NA)
  text <- draft_challenge_model(cfg, "my-model", sheet = sheet)
  expect_match(text, "^# Save as challenge-model.yaml")
  parsed <- parse_challenge_model(text, cfg)
  expect_false(any(parsed$problems$severity == "error"))
  expect_equal(parsed$models$model_id, "my-model")
  expect_equal(parsed$models$long_name, "Form name")
  expect_equal(parsed$models$dynamic, "Yes")
  expect_equal(parsed$models$uses_drivers, "Yes and at least one is estimated from data")
  expect_false("model_type" %in% names(parsed$models))

  file <- withr::local_tempfile(fileext = ".yaml")
  draft_challenge_model(cfg, "form-only", sheet = sheet, file = file)
  expect_equal(parse_challenge_model(paste(readLines(file), collapse = "\n"), cfg)$models$dynamic, "No")
  expect_error(draft_challenge_model(cfg, "nobody", sheet = sheet), "not in the registration sheet")
})

test_that("published models that no repository claims are listed for an invitation", {
  cfg <- test_config()
  testthat::local_mocked_bindings(
    published_model_ids = function(cfg) c("my-model", "form-only", "stranger", "climatology")
  )
  registry <- list(models = tibble::tibble(model_id = "my-model"))
  out <- unregistered_bucket_models(cfg, registry, sheet = sheet_fixture(cfg))
  # climatology is a baseline of the test config, my-model is registered.
  expect_equal(out$model_id, c("form-only", "stranger"))
  expect_equal(names(out), c("model_id", "contact_name", "code_url"))
  expect_true(all(is.na(out$code_url)))
})
