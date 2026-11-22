# A small challenge repository in a temporary folder.
local_challenge_repo <- function(env = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = env)
  cfg <- yaml::read_yaml(test_path("fixtures", "minimal_config.yaml"))
  cfg$sites$metadata_url <- "sites.csv"
  cfg$target_groups$Lakes$targets_script <- "challenge/targets/lakes_targets.R"
  yaml::write_yaml(cfg, file.path(root, "challenge_configuration.yaml"))
  file.copy(test_path("fixtures", "sites.csv"), file.path(root, "sites.csv"))
  dir.create(file.path(root, "challenge", "targets"), recursive = TRUE)
  writeLines("# targets", file.path(root, "challenge", "targets", "lakes_targets.R"))
  root
}

test_that("a consistent challenge repository has no problems", {
  root <- local_challenge_repo()
  problems <- check_challenge_repo(root)
  expect_equal(problems$severity[problems$severity == "error"], character(0))
})

test_that("missing files named by the config are errors", {
  root <- local_challenge_repo()
  unlink(file.path(root, "challenge", "targets", "lakes_targets.R"))
  unlink(file.path(root, "sites.csv"))
  problems <- check_challenge_repo(root)
  expect_setequal(problems$key[problems$severity == "error"],
                  c("target_groups$Lakes$targets_script", "sites$metadata_url"))
})

test_that("the GitHub registry must exist when it is a local file", {
  root <- local_challenge_repo()
  path <- file.path(root, "challenge_configuration.yaml")
  cfg <- yaml::read_yaml(path)
  cfg$submissions$repos$registry <- "registry/forecast_repos.csv"
  yaml::write_yaml(cfg, path)
  problems <- check_challenge_repo(root)
  expect_equal(problems$key[problems$severity == "error"], "submissions$repos$registry")

  dir.create(file.path(root, "registry"))
  writeLines("repo,repo_id,registered", file.path(root, "registry", "forecast_repos.csv"))
  expect_equal(nrow(check_challenge_repo(root)), 0)

  # A URL is not checked.
  cfg$submissions$repos$registry <- "https://example.org/repos.csv"
  yaml::write_yaml(cfg, path)
  expect_equal(nrow(check_challenge_repo(root)), 0)
})
