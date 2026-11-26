test_that("bucket_uri() formats paths for each tool", {
  cfg <- test_config()
  expect_equal(bucket_uri(cfg, "forecasts_bucket", "bundled-parquet"),
               "s3://test-bucket/challenges/forecasts/bundled-parquet")
  expect_equal(bucket_uri(cfg, "forecasts_bucket", "bundled-parquet", scheme = "remote"),
               "main/test-bucket/challenges/forecasts/bundled-parquet")
  expect_equal(bucket_uri(cfg, "scores_bucket", scheme = "https"),
               "https://s3.example.org/test-bucket/challenges/scores")
})

test_that("bucket_uri() picks the store, and alias, from the bucket", {
  cfg <- test_config()
  expect_equal(bucket_uri(cfg, "submissions_bucket", "raw", scheme = "remote"),
               "submissions/submissions/raw")
  expect_equal(bucket_uri(cfg, "scratch", "score_me", scheme = "https"),
               "https://scratch.example.org/scratch-bucket/tmp/score_me")
  expect_equal(bucket_uri(cfg, "forecasts_bucket", scheme = "remote", alias = "osn"),
               "osn/test-bucket/challenges/forecasts")
})

test_that("bucket_uri() tidies stray slashes", {
  cfg <- test_config()
  expect_equal(bucket_uri(cfg, "targets_bucket", "/project_id=x/", "a.csv"),
               "s3://test-bucket/challenges/targets/project_id=x/a.csv")
})

test_that("bucket_uri() names a missing bucket setting", {
  expect_error(bucket_uri(test_config(), "archive_bucket"), "archive_bucket")
})

test_that("store_credentials() reads the configured environment variables", {
  cfg <- test_config()
  withr::local_envvar(S3_ACCESS_KEY_ID = "k", S3_SECRET_ACCESS_KEY = "s")
  expect_equal(store_credentials(cfg, "main"),
               list(endpoint = "s3.example.org", key = "k", secret = "s"))
  # NOAA falls back to the main endpoint and credentials.
  expect_equal(store_credentials(cfg, "noaa")$key, "k")
})

test_that("store_credentials() explains missing credentials", {
  cfg <- test_config()
  withr::local_envvar(EFI_NRP_KEY = NA, EFI_NRP_SECRET = NA)
  expect_error(store_credentials(cfg, "scratch"), "EFI_NRP_KEY")
  expect_equal(store_credentials(cfg, "scratch", anonymous = TRUE),
               list(endpoint = "scratch.example.org", key = "", secret = ""))
})

test_that("store_credentials() rejects unknown stores", {
  expect_error(store_credentials(test_config(), "osn"), "main")
})

test_that("duckdb secrets are scoped to each store's bucket", {
  cfg <- test_config()
  expect_equal(store_bucket(cfg, "main"), "test-bucket")
  expect_equal(store_bucket(cfg, "scratch"), "scratch-bucket")
  expect_null(store_bucket(list(), "scratch"))
})

test_that("with_retry() retries, then re-raises the last error", {
  attempts <- 0
  flaky <- function() {
    attempts <<- attempts + 1
    if (attempts < 2) stop("network blip")
    "ok"
  }
  expect_warning(result <- with_retry(flaky(), times = 3, wait = 0), "network blip")
  expect_equal(result, "ok")
  expect_equal(attempts, 2)

  expect_error(
    suppressWarnings(with_retry(stop("down"), times = 2, wait = 0)),
    "Failed after 2 attempts"
  )
})

test_that("local_duckdb() is separate from, and leaves alone, the shared connection", {
  shared <- duckdbfs::cached_connection()
  inner <- NULL
  f <- function() {
    conn <- local_duckdb()
    inner <<- conn
    expect_false(identical(conn, shared))
    DBI::dbGetQuery(conn, "SELECT 1 AS x")$x
  }
  expect_equal(f(), 1)
  expect_false(DBI::dbIsValid(inner))
  expect_true(DBI::dbIsValid(shared))
})

test_that("open_dataset_if_any() returns NULL for a dataset with no files", {
  conn <- local_duckdb()
  dir <- withr::local_tempdir()
  expect_null(open_dataset_if_any(file.path(dir, "**"), conn = conn))
  arrow::write_parquet(data.frame(x = 1:3), file.path(dir, "a.parquet"))
  expect_equal(nrow(dplyr::collect(open_dataset_if_any(file.path(dir, "**"), conn = conn))), 3)
})

test_that("store_region() reads Backblaze endpoints, else the config, else us-east-1", {
  b2 <- list(endpoint = "s3.us-east-005.backblazeb2.com")
  expect_equal(store_region(b2), "us-east-005")
  expect_equal(store_region(list(endpoint = "sdsc.osn.xsede.org")), "us-east-1")
  expect_equal(store_region(list(endpoint = "sdsc.osn.xsede.org", region = "eu-west-1")),
               "eu-west-1")
  expect_equal(store_region(utils::modifyList(b2, list(region = "x"))), "x")
})

test_that("public URIs name the region only when it is not the default", {
  cfg <- list(endpoint = "sdsc.osn.xsede.org", forecasts_bucket = "b/forecasts")
  expect_equal(public_s3_uri(cfg, "forecasts_bucket"),
               "s3://anonymous@b/forecasts?endpoint_override=sdsc.osn.xsede.org")
  cfg <- list(endpoint = "s3.us-east-005.backblazeb2.com", forecasts_bucket = "b/forecasts")
  expect_equal(public_s3_uri(cfg, "forecasts_bucket"),
               paste0("s3://anonymous@b/forecasts?endpoint_override=",
                      "s3.us-east-005.backblazeb2.com&region=us-east-005"))
})

test_that("with_retry(retry_if =) repeats only what it is told to, and raises the original error", {
  failing_with <- function(first, then = "ok") {
    calls <- 0
    function() {
      calls <<- calls + 1
      if (calls <= length(first)) stop(first[[calls]])
      then
    }
  }
  transient <- function(e) grepl("blip", conditionMessage(e))

  # A transient failure is repeated, quietly (a message, not a warning).
  flaky <- failing_with(list(simpleError("a blip"), simpleError("another blip")))
  expect_message(result <- with_retry(flaky(), times = 4, wait = 0, retry_if = transient), "retrying")
  expect_equal(result, "ok")

  # Anything else is raised at once, unchanged (its class is kept).
  refused <- failing_with(list(structure(class = c("http_403", "error", "condition"),
                                         list(message = "Access Denied", call = NULL))))
  calls <- 0
  err <- expect_error(with_retry({ calls <- calls + 1; refused() }, times = 4, wait = 0,
                                 retry_if = transient), "Access Denied")
  expect_s3_class(err, "http_403")
  expect_equal(calls, 1)

  # When every attempt fails the last error is raised unchanged, not wrapped.
  calls <- 0
  err <- suppressMessages(expect_error(
    with_retry({ calls <- calls + 1; stop(structure(class = c("http_503", "error", "condition"),
                                                    list(message = "still a blip", call = NULL))) },
               times = 3, wait = 0, retry_if = transient), "still a blip"))
  expect_s3_class(err, "http_503")
  expect_equal(calls, 3)
})
