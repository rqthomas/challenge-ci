# Shared by the GitHub submission, registration and metadata tests.

model_yaml <- function(...) {
  paste0("challenge: testcast\nmodels:\n  - model_id: my-model\n", ...)
}

tree_fixture <- function() {
  blob <- function(path, size = 100) {
    tibble::tibble(path = path, type = "blob", sha = paste0("sha-", path), size = size)
  }
  dplyr::bind_rows(
    blob("challenge-model.yaml"),
    blob("README.md"),
    blob("forecasts/lakes-2026-01-01-my-model.csv.gz"),
    blob("forecasts/lakes-2026-01-02-my-model.csv.gz"),
    blob("forecasts/lakes-2026-01-03-other-model.csv"),
    blob("forecasts/birds-2026-01-03-my-model.csv"),
    blob("forecasts/other-2026-01-03-my-model.csv"),
    blob("forecasts/notes.csv"),
    blob("forecasts/lakes-2026-01-04-my-model.csv", size = 500e6),
    blob("elsewhere/lakes-2026-01-01-my-model.csv"),
    tibble::tibble(path = "forecasts", type = "tree", sha = "t", size = NA_real_)
  )
}

mock_github <- function(env = parent.frame(), private = FALSE, id = "7",
                        yaml = model_yaml("    long_name: M\n    description: D\n")) {
  testthat::local_mocked_bindings(
    github_repo_info = function(repo) {
      if (repo == "gone/repo") stop("HTTP 404 Not Found")
      list(id = id, full_name = repo, default_branch = "main", private = private)
    },
    github_tree = function(repo, branch) tree_fixture(),
    github_text = function(repo, sha) yaml,
    .env = env
  )
}

github_cfg <- function() {
  cfg <- test_config()
  cfg$submissions$github$registry <- "unused.csv"
  cfg$processed_submissions <- "test-bucket/challenges/metadata/processed_submissions.csv"
  cfg
}
