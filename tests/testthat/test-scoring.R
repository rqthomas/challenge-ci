scored_row <- function(...) {
  defaults <- list(
    project_id = "p", site_id = "AAAA",
    datetime = as.POSIXct("2024-03-02", tz = "UTC"),
    duration = "P1D", variable = "temperature", model_id = "m", family = "normal",
    reference_datetime = as.POSIXct("2024-03-01", tz = "UTC"),
    pub_datetime = as.POSIXct("2024-03-01 12:00:00", tz = "UTC"),
    observation = 10, crps = 0.5
  )
  # modifyList() drops NULLs but keeps NA, which the tests need.
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

test_that("new scores replace old scores for the same forecast row", {
  dir <- withr::local_tempdir()
  existing <- file.path(dir, "scores.parquet")
  old <- dplyr::bind_rows(
    scored_row(),                                                   # rescored below
    scored_row(site_id = "BBBB"),                                   # kept
    scored_row(site_id = NA, crps = 0.7)                            # NA key, rescored
  )
  duckdbfs::write_dataset(old, existing)
  new <- dplyr::bind_rows(
    scored_row(observation = 11, crps = 0.9),   # revised observation
    scored_row(site_id = NA, crps = 0.8)
  )
  merged <- merge_scores(new, existing) |>
    dplyr::collect() |>
    dplyr::arrange(.data$site_id)
  expect_equal(nrow(merged), 3)
  expect_equal(merged$crps, c(0.9, 0.5, 0.8))
})

test_that("with no existing scores, new scores are de-duplicated", {
  merged <- merge_scores(dplyr::bind_rows(scored_row(), scored_row()), NULL) |>
    dplyr::collect()
  expect_equal(nrow(merged), 1)
})

test_that("score_rows() matches score4cast", {
  skip_if_not_installed("score4cast")
  joined <- example_forecast() |>
    dplyr::mutate(observation = 11)
  scores <- score_rows(joined)
  expect_equal(nrow(scores), nrow(joined) / 2)
  # CRPS of N(10, 1) at 11.
  expected <- scoringRules::crps_norm(11, mean = 10, sd = 1)
  expect_equal(unique(scores$crps), expected)
  expect_true(all(c("logs", "mean", "quantile97.5", "observation") %in% names(scores)))
})

# A local stand-in for the buckets: bundled forecasts (and scores) under `root`,
# and targets in a local file. Returns the config.
local_scoring_store <- function(root, with_forecasts = TRUE, env = parent.frame()) {
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = file.path(root, "dry"), .local_envir = env)
  cfg <- test_config()
  targets <- tibble::tibble(
    project_id = "testcast", site_id = "AAAA", duration = "P1D", variable = "temperature",
    datetime = as.POSIXct(c("2024-03-02", "2024-03-03"), tz = "UTC"), observation = c(10, 11)
  )
  cfg$target_groups$Lakes$targets_file <- file.path(root, "targets.csv")
  readr::write_csv(targets, cfg$target_groups$Lakes$targets_file)

  if (with_forecasts) {
    fc <- example_forecast()
    fc$pub_datetime <- as.POSIXct("2024-03-01 12:00:00", tz = "UTC")
    dir.create(file.path(root, "forecasts"), recursive = TRUE)
    duckdbfs::write_dataset(fc, file.path(root, "forecasts", "bundled-parquet"),
                            format = "parquet", partitioning = c("project_id", "variable"))
  }
  testthat::local_mocked_bindings(
    bucket_uri = function(cfg, key, ..., scheme = "s3", alias = NULL) {
      base <- switch(key, forecasts_bucket = "forecasts", scores_bucket = "scores",
                     scratch = "scratch")
      path <- paste(c(root, base, ...), collapse = "/")
      # duckdbfs adds the glob to a remote folder itself; a local folder needs it.
      if (basename(path) == "bundled-parquet") paste0(path, "/**") else path
    },
    duckdb_connect = function(...) invisible(NULL),
    .env = env
  )
  cfg
}

test_that("a new challenge with no scores yet is scored from scratch", {
  skip_if_not_installed("duckdbfs")
  root <- withr::local_tempdir()
  cfg <- local_scoring_store(root)
  conn <- local_duckdb()
  groups <- suppressMessages(prepare_scoring(cfg, since = as.Date("2024-01-01"), conn = conn))
  expect_equal(groups$model_id, "my-model")
  expect_equal(groups$variable, "temperature")
})

test_that("with no bundled forecasts yet there is nothing to score", {
  skip_if_not_installed("duckdbfs")
  root <- withr::local_tempdir()
  cfg <- local_scoring_store(root, with_forecasts = FALSE)
  conn <- local_duckdb()
  groups <- suppressMessages(prepare_scoring(cfg, since = as.Date("2024-01-01"), conn = conn))
  expect_equal(nrow(groups), 0)
})
