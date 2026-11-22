# Shared by the repository submission, registration and metadata tests. The git
# route is mocked: git_open(), git_tree() and git_text() stand in for a clone.

model_yaml <- function(...) {
  paste0("challenge: testcast\nmodels:\n  - model_id: my-model\n", ...)
}

tree_fixture <- function() {
  blob <- function(path) {
    tibble::tibble(path = path, type = "blob", sha = paste0("sha-", path), size = NA_real_)
  }
  dplyr::bind_rows(
    blob("challenge-model.yaml"),
    blob("README.md"),
    blob("forecasts/2026-01-01.csv.gz"),
    blob("forecasts/2026-01-02.csv.gz"),
    blob("forecasts/anything.csv"),
    blob("forecasts/notes.txt"),
    blob("elsewhere/2026-01-01.csv"),
    tibble::tibble(path = "forecasts", type = "tree", sha = "t", size = NA_real_)
  )
}

mock_git <- function(env = parent.frame(),
                     yaml = model_yaml("    long_name: M\n    description: D\n")) {
  testthat::local_mocked_bindings(
    git_open = function(url, timeout = 120) {
      if (grepl("gone/repo", url)) {
        stop("the repository could not be cloned anonymously (private, missing or unreachable)")
      }
      list(dir = NULL, branch = "main", commit = "abc")
    },
    git_tree = function(handle) tree_fixture(),
    git_text = function(handle, sha, max_bytes = 1e6) yaml,
    .env = env
  )
}

github_cfg <- function() {
  cfg <- test_config()
  cfg$submissions$repos$registry <- "unused.csv"
  cfg$processed_submissions <- "test-bucket/challenges/metadata/processed_submissions.csv"
  cfg
}

repo_row <- function(repo, location = "repo") {
  tibble::tibble(repo = repo, location = location, registered = NA_character_)
}

# The state run_submissions() builds, for calling the processors directly.
new_state <- function(registry = NULL, record = empty_record(), units = new_units(),
                      env = parent.frame()) {
  state <- new.env()
  state$record <- record
  state$units <- units
  state$work_dir <- withr::local_tempdir(.local_envir = env)
  state$time_stamp <- "20260101000000"
  state$pending <- 0L
  state$delete_queue <- character()
  state$remove <- NULL
  state$n_removed <- 0L
  state$rules <- submission_rules(test_config())
  state$registry <- registry
  state
}

# example_forecast() issued `days` days after its usual reference date.
forecast_on <- function(days = 0, ...) {
  fc <- example_forecast(...)
  shift <- days * 86400
  fc$reference_datetime <- fc$reference_datetime + shift
  fc$datetime <- fc$datetime + shift
  fc
}
