test_that("plan_submissions() skips processed and excluded keys", {
  keys <- c("a.csv", "b.csv", "x-2023-01-01-m.csv", "usgsrc4cast/c.csv", "d.csv")
  plan <- plan_submissions(keys, processed = c("a.csv", "gone.csv"),
                           exclude_patterns = c("2023", "usgsrc4cast"))
  expect_equal(plan$download, c("b.csv", "d.csv"))
  expect_equal(plan$stale, "a.csv")
  expect_equal(plan$n_excluded, 2)
})

write_submission <- function(fc, name) {
  path <- file.path(withr::local_tempdir(.local_envir = parent.frame()), name)
  readr::write_csv(fc, path)
  path
}

test_that("a valid submission is written as parquet and summaries", {
  skip_if_not_installed("score4cast")
  path <- write_submission(example_forecast(), "lakes-2024-03-01-my-model.csv.gz")
  out <- withr::local_tempdir()
  res <- process_submission(path, test_config(), out)
  expect_equal(res$status, "processed")
  # One reference date: one partition, one file each.
  expect_length(list.files(file.path(out, "parquet"), recursive = TRUE), 1)
  expect_length(list.files(file.path(out, "summaries"), recursive = TRUE), 1)
})

test_that("an invalid submission is reported, not written", {
  path <- write_submission(dplyr::select(example_forecast(), -"family"),
                           "lakes-2024-03-01-my-model.csv")
  out <- withr::local_tempdir()
  res <- suppressMessages(process_submission(path, test_config(), out))
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "family")
  expect_length(list.files(out, recursive = TRUE), 0)
})

test_that("files that cannot be processed are skipped with a reason", {
  cfg <- test_config()
  cfg$submissions$min_reference_date <- "2024-01-01"
  out <- withr::local_tempdir()
  skip_reason <- function(name) {
    res <- process_submission(write_submission(example_forecast(), name), cfg, out)
    expect_equal(res$status, "skipped")
    res$reason
  }
  expect_match(skip_reason("my forecast.csv"), "name")
  expect_match(skip_reason("lakes-2024-03-01-m.parquet"), "parquet")
  expect_match(skip_reason("lakes-2023-12-31-m.csv"), "before 2024-01-01")
})

test_that("plan_submissions() can keep to the challenge's own themes", {
  keys <- c("lakes-2026-01-01-m1.csv", "aquatics-2026-01-01-m1.csv", "notes.txt")
  plan <- plan_submissions(keys, processed = character(), themes = "lakes")
  expect_equal(plan$download, "lakes-2026-01-01-m1.csv")
  expect_equal(plan$n_excluded, 2)
  expect_equal(challenge_themes(test_config()), c("lakes", "birds"))
})

# Ownership of bucket files -----------------------------------------------------

test_that("bucket files are matched to registered models by their name", {
  models <- tibble::tibble(model_id = c("a", "b"), location = c("bucket", "repo"),
                           repo = c("github.com/x/a", "github.com/y/b"))
  keys <- c("lakes-2026-01-01-a.csv", "lakes-2026-01-01-b.csv", "lakes-2026-01-01-c.csv",
            "lakes-2026-01-01-climatology.csv", "notes.csv")
  # b is registered to a repository (skipped); c is not registered (processed
  # with a note); the baseline and a badly named file are processed.
  plan <- plan_bucket_ownership(keys, models, baseline_ids = "climatology")
  expect_equal(plan$action[2], "skip")
  expect_match(plan$reason[2], "github.com/y/b, not the bucket")
  expect_equal(plan$action[-2], rep("process", 4))
  expect_match(plan$note[3], "not registered")
  expect_equal(plan$registered, c(TRUE, TRUE, FALSE, TRUE, NA))

  strict <- plan_bucket_ownership(keys, models, baseline_ids = "climatology", strict = TRUE)
  expect_equal(strict$action, c("process", "skip", "skip", "process", "process"))
  expect_match(strict$reason[3], "not registered")
  expect_true(is.na(strict$note[3]))

  # No registry: everything is processed, as before.
  open <- plan_bucket_ownership(keys, NULL)
  expect_equal(open$action, rep("process", 5))
  expect_equal(nrow(plan_bucket_ownership(character(), models)), 0)
})

test_that("old-format bucket files are accepted until strict_from", {
  cfg <- test_config()
  expect_false(bucket_is_strict(cfg))
  cfg$submissions$bucket$strict_from <- "2027-01-01"
  expect_false(bucket_is_strict(cfg, today = as.Date("2026-12-31")))
  expect_true(bucket_is_strict(cfg, today = as.Date("2027-01-01")))
})

# One file ------------------------------------------------------------------------

old_format <- function() {
  dplyr::select(example_forecast(), -"model_id", -"duration", -"project_id")
}

test_that("an old-format bucket file is filled in while legacy, invalid after", {
  skip_if_not_installed("score4cast")
  path <- write_submission(old_format(), "lakes-2024-03-01-my-model.csv.gz")
  out <- withr::local_tempdir()
  res <- suppressMessages(process_submission(path, test_config(), out,
                                             context = list(legacy = TRUE)))
  expect_equal(res$status, "processed")
  expect_match(res$warnings, "no model_id column")
  expect_equal(res$model_id, "my-model")

  res <- suppressMessages(process_submission(path, test_config(), withr::local_tempdir()))
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "model_id")
  expect_match(res$reason, "duration")
})

test_that("a repository file has a free name but needs its columns and an allowed model", {
  skip_if_not_installed("score4cast")
  cfg <- test_config()
  path <- write_submission(example_forecast(), "my forecast, final.csv")
  run <- function(path, ...) {
    suppressMessages(process_submission(path, cfg, withr::local_tempdir(),
                                        context = list(route = "repo", ...)))
  }
  res <- run(path, allowed = "my-model")
  expect_equal(res$status, "processed")
  expect_equal(res$rows_kept, 12)

  res <- run(path, allowed = "someone-else")
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "not listed for this folder")

  no_duration <- write_submission(dplyr::select(example_forecast(), -"duration"), "f.csv")
  expect_match(run(no_duration)$reason, "duration")
  expect_equal(run(write_submission(example_forecast(), "f.parquet"))$status, "skipped")
})

test_that("a bucket file's model_id column must agree with its name", {
  path <- write_submission(example_forecast(), "lakes-2024-03-01-someone-else.csv")
  res <- suppressMessages(process_submission(path, test_config(), withr::local_tempdir()))
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "my-model.*someone-else")
})

test_that("only this challenge's rows are stored, and a file with none is skipped", {
  skip_if_not_installed("score4cast")
  cfg <- test_config()
  mixed <- dplyr::bind_rows(
    example_forecast(),
    dplyr::mutate(example_forecast(), project_id = "other"),
    dplyr::mutate(example_forecast(), site_id = "CCCC")
  )
  res <- suppressMessages(process_submission(
    write_submission(mixed, "lakes-2024-03-01-my-model.csv"), cfg, withr::local_tempdir()))
  expect_equal(res$status, "processed")
  expect_equal(c(res$rows_kept, res$rows_dropped), c(12, 24))
  expect_match(res$warnings, "dropped 24 rows")

  elsewhere <- dplyr::mutate(example_forecast(), project_id = "other")
  res <- suppressMessages(process_submission(
    write_submission(elsewhere, "lakes-2024-03-01-my-model.csv"), cfg, withr::local_tempdir()))
  expect_equal(res$status, "skipped")
  expect_match(res$reason, "no rows for this challenge")
  expect_equal(res$rows_kept, 0)
})

test_that("the first rows stored for a unit win, the rest of the file is stored", {
  skip_if_not_installed("score4cast")
  cfg <- test_config()
  both <- dplyr::bind_rows(example_forecast(),
                           dplyr::mutate(example_forecast(), variable = "oxygen"))
  path <- write_submission(both, "lakes-2024-03-01-my-model.csv")
  stored <- new_units(unit_keys("my-model", "2024-03-01", "temperature", "P1D"))
  out <- withr::local_tempdir()
  res <- suppressMessages(process_submission(path, cfg, out, context = list(units = stored)))
  expect_equal(res$status, "processed")
  expect_equal(res$units, unit_keys("my-model", "2024-03-01", "oxygen", "P1D"))
  expect_match(res$warnings, "1 unit already stored")
  expect_true(any(grepl("variable=oxygen", list.files(out, recursive = TRUE))))
  expect_false(any(grepl("variable=temperature", list.files(out, recursive = TRUE))))

  all_stored <- new_units(unit_keys("my-model", "2024-03-01", c("temperature", "oxygen"), "P1D"))
  res <- suppressMessages(process_submission(path, cfg, withr::local_tempdir(),
                                             context = list(units = all_stored)))
  expect_equal(res$status, "skipped")
  expect_match(res$reason, "stored already")
})

test_that("a backfill file is checked unit by unit across reference dates", {
  skip_if_not_installed("score4cast")
  backfill <- dplyr::bind_rows(forecast_on(0), forecast_on(1), forecast_on(2))
  stored <- new_units(unit_keys("my-model", "2024-03-02", "temperature", "P1D"))
  res <- suppressMessages(process_submission(
    write_submission(backfill, "lakes-2024-03-01-my-model.csv"), test_config(),
    withr::local_tempdir(), context = list(units = stored)))
  expect_equal(res$status, "processed")
  expect_equal(sort(res$units), sort(unit_keys("my-model", c("2024-03-01", "2024-03-03"),
                                               "temperature", "P1D")))
})

test_that("a file over the size limit or a Git LFS pointer is invalid", {
  big <- write_submission(example_forecast(), "lakes-2024-03-01-my-model.csv")
  res <- process_submission(big, test_config(), withr::local_tempdir(),
                            context = list(max_bytes = 10))
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "larger than")

  pointer <- file.path(withr::local_tempdir(), "lakes-2024-03-01-my-model.csv")
  writeLines(c("version https://git-lfs.github.com/spec/v1", "oid sha256:ab", "size 9"), pointer)
  res <- process_submission(pointer, test_config(), withr::local_tempdir())
  expect_match(res$reason, "Git LFS")
})

# The record and the units ------------------------------------------------------------

test_that("the record is written in batches, and deletions wait for a written record", {
  cfg <- test_config()
  state <- new_state()
  log <- character()
  state$remove <- function(key) {
    log <<- c(log, paste0("delete:", key))
    1L
  }
  testthat::local_mocked_bindings(
    store_submission = function(...) list(status = "processed", reason = "ok"),
    write_manifest = function(cfg, record) log <<- c(log, paste0("write:", nrow(record))),
    write_units = function(cfg, units) log <<- c(log, "units")
  )
  state$units$dirty <- TRUE
  for (i in 1:60) {
    suppressMessages(handle_submission(
      cfg, state, key = paste0("k", i), source = "bucket", sha = NA_character_, model_id = "m",
      fetch = function(local) writeLines("x", local), context = list(), delete_after = TRUE
    ))
  }
  # Two batches of 25 so far; 10 files wait for the final write.
  expect_equal(log[c(1, 2)], c("units", "write:25"))
  expect_equal(sum(grepl("^write", log)), 2)
  expect_equal(which(grepl("^delete", log))[1], 3)
  expect_equal(sum(grepl("^delete", log)), 50)
  flush_state(cfg, state)
  expect_equal(sum(grepl("^write", log)), 3)
  expect_equal(sum(grepl("^delete", log)), 60)
  expect_equal(nrow(state$record), 60)
  expect_equal(state$n_removed, 60)
})

test_that("a failed or unreadable file is not recorded", {
  cfg <- test_config()
  state <- new_state()
  testthat::local_mocked_bindings(
    store_submission = function(...) stop("upload broke")
  )
  res <- suppressMessages(handle_submission(
    cfg, state, "a", "bucket", NA_character_, "m", function(local) writeLines("x", local), list()
  ))
  expect_equal(res$status, "failed")
  res <- suppressWarnings(handle_submission(
    cfg, state, "b", "bucket", NA_character_, "m", function(local) stop("no"), list()
  ))
  expect_equal(res$status, "unreadable")
  expect_equal(nrow(state$record), 0)
})

test_that("the record keeps skipped repository files by SHA and an old record still reads", {
  record <- tibble::tibble(key = c("a.csv", "r/x.csv", "r/y.csv"),
                           sha = c(NA, "s1", "s2"),
                           status = c("processed", "skipped", "invalid"))
  expect_setequal(manifest_tokens(record), c("a.csv", "r/x.csv@s1", "r/y.csv"))

  path <- withr::local_tempfile(fileext = ".csv")
  writeLines(c("key", "old1.csv", "old2.csv"), path)
  testthat::local_mocked_bindings(
    remote_exists = function(...) TRUE,
    remote_download = function(remote, local) file.copy(path, local, overwrite = TRUE)
  )
  old <- read_manifest(github_cfg())
  expect_equal(old$key, c("old1.csv", "old2.csv"))
  expect_equal(old$status, c("processed", "processed"))
  expect_equal(manifest_tokens(old), c("old1.csv", "old2.csv"))
})

test_that("the unit record is written next to the processed record and read back", {
  cfg <- test_config()
  cfg$processed_submissions <- "test-bucket/challenges/metadata/processed_submissions.csv"
  expect_match(units_remote(cfg), "processed_submissions_units.csv$")

  units <- new_units()
  units_add(units, unit_keys("m", "2024-03-01", c("temperature", "oxygen"), "P1D"))
  expect_true(units$dirty)
  expect_equal(units_has(units, unit_keys("m", "2024-03-01", c("temperature", "salinity"), "P1D")),
               c(TRUE, FALSE))

  written <- withr::local_tempfile(fileext = ".csv")
  testthat::local_mocked_bindings(
    upload_file = function(local, remote) file.copy(local, written, overwrite = TRUE),
    remote_exists = function(...) TRUE,
    remote_download = function(remote, local) file.copy(written, local, overwrite = TRUE)
  )
  write_units(cfg, units)
  rows <- readr::read_csv(written, show_col_types = FALSE)
  expect_equal(names(rows), c("model_id", "reference_date", "variable", "duration"))
  expect_equal(nrow(rows), 2)
  back <- read_units(cfg)
  expect_false(back$dirty)
  expect_equal(units_has(back, unit_keys("m", "2024-03-01", c("oxygen", "salinity"), "P1D")),
               c(TRUE, FALSE))
})
