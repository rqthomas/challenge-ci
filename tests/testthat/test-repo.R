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
