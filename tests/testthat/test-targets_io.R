targets_fixture <- function(n_sites = 2, days = 3) {
  tidyr::expand_grid(site_id = c("AAAA", "BBBB", "CCCC")[seq_len(n_sites)],
                     datetime = as.Date("2024-03-01") + 0:(days - 1),
                     variable = c("temperature", "oxygen")) |>
    dplyr::mutate(observation = 1)
}

test_that("targets_object() turns the targets URL into a store path", {
  cfg <- test_config()
  expect_equal(targets_object(cfg, "Lakes"), "main/test-bucket/lakes-targets.csv.gz")
  cfg$target_groups$Lakes$targets_file <- "https://elsewhere.org/x.csv"
  expect_error(targets_object(cfg, "Lakes"), "must be a URL starting")
})

test_that("format_targets() gives the standard columns and types", {
  raw <- targets_fixture() |> dplyr::mutate(observation = c(NaN, rep(2, 11)))
  out <- format_targets(raw, test_config(), "P1D")
  expect_named(out, c("project_id", "site_id", "datetime", "duration", "variable", "observation"))
  expect_s3_class(out$datetime, "POSIXct")
  expect_equal(unique(out$project_id), "testcast")
  expect_equal(sum(is.na(out$observation)), 1)
  expect_false(any(is.nan(out$observation)))
  expect_error(format_targets(dplyr::select(raw, -"site_id"), test_config(), "P1D"), "site_id")
})

test_that("check_targets() passes good targets", {
  cfg <- test_config()
  new <- format_targets(targets_fixture(days = 4), cfg, "P1D")
  old <- format_targets(targets_fixture(days = 3), cfg, "P1D")
  expect_message(out <- check_targets(new, cfg, "Lakes", published = old), "published")
  expect_identical(out, new)
  # Nothing published yet.
  expect_silent(check_targets(new, cfg, "Lakes", published = NULL))
})

test_that("check_targets() stops bad targets from replacing good ones", {
  cfg <- test_config()
  old <- format_targets(targets_fixture(n_sites = 2, days = 10), cfg, "P1D")
  fails <- function(new, pattern) {
    expect_error(suppressMessages(check_targets(new, cfg, "Lakes", published = old)), pattern)
  }
  fails(format_targets(targets_fixture(n_sites = 2, days = 5), cfg, "P1D"), "fewer than 95%")
  fails(format_targets(targets_fixture(n_sites = 1, days = 20), cfg, "P1D"), "sites missing: BBBB")
  fails(dplyr::filter(old, variable == "oxygen") |>
          dplyr::bind_rows(dplyr::mutate(dplyr::filter(old, variable == "oxygen"),
                                         datetime = datetime + 86400 * 30)),
        "variables missing: temperature")
  fails(dplyr::bind_rows(old, old[1, ]), "1 duplicated")
  fails(dplyr::mutate(old, variable = dplyr::if_else(variable == "oxygen", "salinity", variable)),
        "not in the config: salinity")
  fails(dplyr::select(old, -"duration"), "standard")
})

test_that("write_targets() uploads to the targets file's location", {
  dir <- withr::local_tempdir()
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = dir)
  cfg <- test_config()
  targets <- format_targets(targets_fixture(), cfg, "P1D")
  expect_message(write_targets(targets, cfg, "Lakes"), "DRY RUN")
  written <- readr::read_csv(file.path(dir, "main/test-bucket/lakes-targets.csv.gz"),
                             show_col_types = FALSE)
  expect_equal(nrow(written), nrow(targets))
})

test_that("targets_files() reads an earlier dry run's targets in a dry run", {
  cfg <- test_config()
  url <- cfg$target_groups$Lakes$targets_file
  dir <- withr::local_tempdir()
  withr::local_envvar(DRY_RUN = "false", DRY_RUN_DIR = dir)
  expect_equal(targets_files(cfg), url)

  withr::local_envvar(DRY_RUN = "true")
  expect_equal(targets_files(cfg), url)  # nothing written yet
  local <- file.path(dir, "main/test-bucket/lakes-targets.csv.gz")
  dir.create(dirname(local), recursive = TRUE)
  file.create(local)
  expect_message(files <- targets_files(cfg), "DRY RUN")
  expect_equal(files, local)
})

private_cfg <- function() {
  cfg <- test_config()
  cfg$public_read <- FALSE
  cfg$target_groups$Lakes$targets_file <- "https://s3.example.org/test-bucket/lakes-targets.csv.gz"
  cfg
}

test_that("reads are anonymous unless public_read is false", {
  expect_true(anonymous_reads(test_config()))
  expect_true(anonymous_reads(list(public_read = TRUE)))
  expect_false(anonymous_reads(list(public_read = FALSE)))
  expect_error(validate_config(utils::modifyList(test_config(), list(public_read = "no"))),
               "public_read")
})

test_that("a public store's targets are read by URL, a private store's are downloaded", {
  cfg <- test_config()
  cfg$target_groups$Lakes$targets_file <- "https://s3.example.org/test-bucket/lakes-targets.csv.gz"
  url <- "https://s3.example.org/test-bucket/lakes-targets.csv.gz"
  expect_equal(targets_files(cfg, url), url)

  downloaded <- NULL
  testthat::local_mocked_bindings(download_targets = function(cfg, object) {
    downloaded <<- object
    "/tmp/local-targets.csv.gz"
  })
  expect_equal(targets_files(private_cfg(), url), "/tmp/local-targets.csv.gz")
  expect_equal(downloaded, "main/test-bucket/lakes-targets.csv.gz")
  # A file outside the store is read as it is.
  expect_equal(targets_files(private_cfg(), "elsewhere/targets.csv"), "elsewhere/targets.csv")
})

test_that("download_targets() copies the object to a local file", {
  copied <- NULL
  testthat::local_mocked_bindings(mc_connect = function(...) invisible(NULL))
  testthat::local_mocked_bindings(
    mc_cp = function(from, to) copied <<- list(from, to),
    .package = "minioclient"
  )
  path <- download_targets(private_cfg(), "main/test-bucket/lakes-targets.csv.gz")
  expect_equal(basename(path), "lakes-targets.csv.gz")
  expect_equal(copied[[1]], "main/test-bucket/lakes-targets.csv.gz")
  expect_equal(copied[[2]], shQuote(path))
})

test_that("the published targets of a private store are downloaded, not fetched by URL", {
  local <- withr::local_tempfile(fileext = ".csv")
  readr::write_csv(tibble::tibble(site_id = "A", observation = 1), local)
  seen <- NULL
  testthat::local_mocked_bindings(
    mc_connect = function(cfg, store, alias = store, anonymous = FALSE) {
      seen <<- list(alias = alias, anonymous = anonymous)
    },
    download_targets = function(cfg, object) local
  )
  testthat::local_mocked_bindings(mc_ls = function(...) "file", .package = "minioclient")
  published <- read_published_targets(private_cfg(), "Lakes")
  expect_equal(published$site_id, "A")
  # The alias is connected with the key.
  expect_false(seen$anonymous)
})

test_that("a store without a key is read anonymously only when it is public", {
  withr::local_envvar(S3_ACCESS_KEY_ID = "", S3_SECRET_ACCESS_KEY = "")
  expect_true(read_anonymously_without_key(test_config()))
  expect_false(read_anonymously_without_key(private_cfg()))
  withr::local_envvar(S3_ACCESS_KEY_ID = "k", S3_SECRET_ACCESS_KEY = "s")
  expect_false(read_anonymously_without_key(test_config()))
})
