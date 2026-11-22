# The whole submissions stage, with the stores and git mocked: two challenges
# read the same repository file, a bucket model and a repository model submit in
# the same run.

run_cfg <- function(project_id = "testcast") {
  cfg <- github_cfg()
  registry <- withr::local_tempfile(fileext = ".csv", .local_envir = parent.frame())
  writeLines(c("repo,location,registered", "alice/forecasts,repo,", "bob/bucketmodel,bucket,"),
             registry)
  cfg$submissions$repos$registry <- registry
  cfg$github_repo <- "owner/challenge"
  if (project_id != "testcast") {
    # A second challenge: lakes B and C only, with its own buckets.
    cfg$project_id <- project_id
    cfg$target_groups$Lakes$sites_column <- "has_birds"
    cfg$target_groups$Birds <- NULL
    cfg$forecasts_bucket <- "test-bucket/other/forecasts"
    cfg$summaries_bucket <- "test-bucket/other/forecasts"
    cfg$processed_submissions <- "test-bucket/other/metadata/processed_submissions.csv"
  }
  cfg
}

# alice's repository serves both challenges from one file; bob's only describes
# a model that submits to the bucket.
mock_run <- function(env = parent.frame()) {
  alice_yaml <- paste0("- challenge: testcast\n  models: [{model_id: alice-model}]\n",
                       "- challenge: othercast\n  models: [{model_id: alice-model}]\n")
  bob_yaml <- paste0("- challenge: testcast\n  models: [{model_id: bucket-model}]\n",
                     "- challenge: othercast\n  models: [{model_id: bucket-model}]\n")
  three_sites <- function(model_id, old = FALSE) {
    fc <- example_forecast()
    site_c <- fc[fc$site_id == "BBBB", ]
    site_c$site_id <- "CCCC"
    fc <- dplyr::bind_rows(fc, site_c)
    fc$model_id <- model_id
    # No project_id label: the file is meant for every challenge that lists it.
    fc$project_id <- NULL
    if (old) fc <- dplyr::select(fc, -"model_id", -"duration")
    fc
  }
  deleted <- character()
  testthat::local_mocked_bindings(
    remote_connect = function(...) invisible(),
    remote_exists = function(...) FALSE,
    remote_files = function(path) {
      tibble::tibble(key = c("lakes-2024-03-01-bucket-model.csv", "lakes-2024-03-01-stranger.csv",
                             "lakes-2024-03-01-alice-model.csv"))
    },
    remote_download = function(remote, local) {
      id <- sub("^lakes-2024-03-01-(.*)\\.csv$", "\\1", basename(remote))
      readr::write_csv(three_sites(id, old = TRUE), local)
    },
    remove_remote = function(path) deleted <<- c(deleted, basename(path)),
    git_open = function(url, timeout = 120) {
      list(dir = NULL, branch = "main", commit = if (grepl("alice", url)) "alice" else "bob")
    },
    git_tree = function(handle) {
      if (handle$commit == "alice") {
        tibble::tibble(path = c("challenge-model.yaml", "forecasts/anything-you-like.csv"),
                       type = "blob", sha = c("sha-yaml", "sha-forecast"), size = NA_real_)
      } else {
        tibble::tibble(path = "challenge-model.yaml", type = "blob", sha = "sha-yaml",
                       size = NA_real_)
      }
    },
    git_text = function(handle, sha, max_bytes = 1e6) {
      if (handle$commit == "alice") alice_yaml else bob_yaml
    },
    git_blob = function(handle, sha, dest, timeout = 300) {
      readr::write_csv(three_sites("alice-model"), dest)
    },
    .env = env
  )
  function() deleted
}

stored_sites <- function(forecasts_bucket) {
  files <- list.files(dry_run_dir(), "\\.parquet$", recursive = TRUE, full.names = TRUE)
  files <- files[grepl(paste0(forecasts_bucket, "/parquet/"), files, fixed = TRUE)]
  by_model <- lapply(files, function(f) {
    d <- as.data.frame(arrow::read_parquet(f))
    # The model is in the partition path, not in the file.
    model <- sub("^.*model_id=([^/]+)/.*$", "\\1", f)
    paste(model, paste(sort(unique(d$site_id)), collapse = ","))
  })
  sort(unlist(by_model))
}

test_that("one file serves two challenges, each keeping its own sites", {
  skip_if_not_installed("score4cast")
  skip_if_not_installed("arrow")
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  deleted <- mock_run()

  res_a <- suppressMessages(run_submissions(run_cfg("testcast")))
  res_b <- suppressMessages(run_submissions(run_cfg("othercast")))

  # alice's repository file: sites A and B for testcast, B and C for othercast.
  for (res in list(res_a, res_b)) {
    mine <- res[res$model_id == "alice-model" & res$status == "processed", ]
    expect_equal(nrow(mine), 1)
    expect_equal(c(mine$rows_kept, mine$rows_dropped), c(12, 6))
    expect_match(mine$warnings, "dropped 6 rows")
    expect_equal(mine$source, "github.com/alice/forecasts")
  }
  expect_true("alice-model AAAA,BBBB" %in% stored_sites("test-bucket/challenges/forecasts"))
  expect_true("alice-model BBBB,CCCC" %in% stored_sites("test-bucket/other/forecasts"))
})

test_that("bucket and repository models are handled in the same run", {
  skip_if_not_installed("score4cast")
  skip_if_not_installed("arrow")
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  deleted <- mock_run()
  res <- suppressMessages(run_submissions(run_cfg()))

  status <- function(key) res$status[!is.na(res$key) & res$key == key]
  # The registered bucket model, in the old format, is accepted while lenient.
  expect_equal(status("lakes-2024-03-01-bucket-model.csv"), "processed")
  # The model nobody registered is processed with a note to register.
  expect_equal(status("lakes-2024-03-01-stranger.csv"), "processed")
  expect_match(res$warnings[!is.na(res$key) & res$key == "lakes-2024-03-01-stranger.csv"],
               "not registered")
  # The model registered for a repository may not use the bucket.
  expect_equal(status("lakes-2024-03-01-alice-model.csv"), "skipped")
  expect_match(res$reason[!is.na(res$key) & res$key == "lakes-2024-03-01-alice-model.csv"],
               "github.com/alice/forecasts, not the bucket")
  # Both repositories are reported.
  expect_equal(sum(res$status == "registered"), 2)
  # The processed bucket files were deleted, once the record was written.
  expect_setequal(deleted(), c("lakes-2024-03-01-bucket-model.csv",
                               "lakes-2024-03-01-stranger.csv"))
})

test_that("from strict_from, unregistered models and old-format files are refused", {
  skip_if_not_installed("score4cast")
  skip_if_not_installed("arrow")
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  mock_run()
  cfg <- run_cfg()
  cfg$submissions$bucket$strict_from <- "2020-01-01"
  res <- suppressMessages(run_submissions(cfg))

  row <- function(key) res[!is.na(res$key) & res$key == key, ]
  expect_equal(row("lakes-2024-03-01-stranger.csv")$status, "skipped")
  expect_match(row("lakes-2024-03-01-stranger.csv")$reason, "not registered")
  # The registered bucket model's old-format file is now invalid.
  expect_equal(row("lakes-2024-03-01-bucket-model.csv")$status, "invalid")
  expect_match(row("lakes-2024-03-01-bucket-model.csv")$reason, "duration")
  # The repository file is unaffected.
  expect_equal(res$status[res$model_id %in% "alice-model" & !is.na(res$rows_kept)], "processed")
})

test_that("the bucket waits when the registry cannot be read", {
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  mock_run()
  cfg <- run_cfg()
  cfg$submissions$repos$registry <- "no-such-registry.csv"
  expect_error(suppressMessages(run_submissions(cfg)), "registry")
})
