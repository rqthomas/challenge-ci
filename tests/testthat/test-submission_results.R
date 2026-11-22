rows <- function(...) {
  results_row(key = "k", model_id = "m1", source = "bucket", sha = "s1",
              status = "processed", reason = "9 rows", ...)
}

stub_published <- function(existing, env = parent.frame()) {
  testthat::local_mocked_bindings(read_published_results = function(remote) existing,
                                  .env = env)
}

empty_published <- function() {
  tibble::tibble(model_id = character(), file = character(), source = character(),
                 sha = character(), first_seen = character(), status = character(),
                 reason = character(), warnings = character())
}

test_that("results are published per model and merged with earlier ones", {
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  old <- empty_published()
  old[1, ] <- list("m1", "a.csv", "bucket", "s0", "2026-01-01T00:00:00Z",
                   "invalid", "no family", "")
  stub_published(old)

  new <- dplyr::bind_rows(
    results_row("a.csv", "m1", "bucket", "s0", "invalid", "no family"),  # repeat
    results_row("b.csv", "m1", "bucket", "s1", "processed", "9 rows"),
    results_row("c.csv", "m2", "github:o/r", "s2", "processed", "3 rows"),
    results_row("d.csv", NA, "bucket", "s3", "skipped", "bad name")      # no model
  )
  written <- suppressMessages(write_submission_results(test_config(), new))
  expect_equal(basename(written), c("m1.csv", "m2.csv"))

  m1 <- readr::read_csv(file.path(dry_run_dir(), written[1]),
                        col_types = readr::cols(.default = "c"))
  expect_equal(m1$file, c("a.csv", "b.csv"))   # the repeat was not added again
  expect_equal(m1$first_seen[1], "2026-01-01T00:00:00Z")
  expect_equal(names(m1), c("model_id", "file", "source", "sha", "first_seen",
                            "status", "reason", "warnings", "rows_kept", "rows_dropped"))
})

test_that("only the latest rows are kept", {
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  stub_published(empty_published())
  cfg <- test_config()
  cfg$submissions$results_max_rows <- 2
  new <- dplyr::bind_rows(lapply(1:4, function(i) {
    results_row(paste0(i, ".csv"), "m1", "bucket", paste0("s", i), "processed", "")
  }))
  written <- suppressMessages(write_submission_results(cfg, new))
  m1 <- readr::read_csv(file.path(dry_run_dir(), written),
                        show_col_types = FALSE)
  expect_equal(m1$file, c("3.csv", "4.csv"))
})

test_that("a publishing failure is a warning, not an error", {
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = withr::local_tempdir())
  testthat::local_mocked_bindings(
    read_published_results = function(remote) stop("network down"))
  expect_warning(
    suppressMessages(write_submission_results(test_config(), rows())),
    "Could not publish"
  )
})

test_that("no rows publishes nothing", {
  expect_length(write_submission_results(test_config(), empty_results()), 0)
})
