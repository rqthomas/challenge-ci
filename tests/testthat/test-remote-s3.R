# Runs the remote helpers against a real S3 endpoint through paws. Skipped unless
# you point it at one, e.g. a local S3 mock or a test bucket:
#
#   CHALLENGECI_TEST_S3_ENDPOINT=http://127.0.0.1:5000   (or s3.us-east-005.backblazeb2.com)
#   CHALLENGECI_TEST_S3_KEY / CHALLENGECI_TEST_S3_SECRET
#   CHALLENGECI_TEST_S3_BUCKET   (must exist; the test works under its own prefix and removes it)
#   CHALLENGECI_TEST_S3_REGION   (optional, default us-east-1)

test_that("the helpers work against a real S3 endpoint", {
  endpoint <- Sys.getenv("CHALLENGECI_TEST_S3_ENDPOINT")
  skip_if(!nzchar(endpoint), "set CHALLENGECI_TEST_S3_ENDPOINT, _KEY, _SECRET and _BUCKET to run")
  bucket <- Sys.getenv("CHALLENGECI_TEST_S3_BUCKET")
  remote_clients[["itest"]] <- s3_client(
    endpoint, Sys.getenv("CHALLENGECI_TEST_S3_REGION", "us-east-1"),
    Sys.getenv("CHALLENGECI_TEST_S3_KEY"), Sys.getenv("CHALLENGECI_TEST_S3_SECRET")
  )
  withr::defer(rm(list = "itest", envir = remote_clients))
  root <- paste0("itest/", bucket, "/challengeci-test-", format(Sys.time(), "%H%M%S"),
                 "-", sample.int(1e6, 1))
  withr::defer(try(remote_delete(root, recursive = TRUE), silent = TRUE))
  withr::local_options(challengeci.multipart_threshold = 1e6, challengeci.part_size = 1e6,
                       challengeci.upload_workers = 2)

  # A folder with a nested key, a hive-style key with "=" and a space, a small file and
  # a large one that goes up in parts.
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "project_id=x", "model one"), recursive = TRUE)
  writeLines("{}", file.path(dir, "meta.json"))
  writeLines("small", file.path(dir, "project_id=x", "model one", "a b.csv"))
  big <- as.raw(rep(0:255, length.out = 12e6))
  writeBin(big, file.path(dir, "big.parquet"))
  suppressMessages(upload_dir(dir, paste0(root, "/up")))

  files <- remote_files(paste0(root, "/up"))
  expect_setequal(files$key, c("meta.json", "project_id=x/model one/a b.csv", "big.parquet"))
  expect_equal(files$bytes[files$key == "big.parquet"], 12e6)
  expect_true(remote_exists(paste0(root, "/up/meta.json")))
  expect_false(remote_exists(paste0(root, "/up/nope.json")))

  got <- withr::local_tempfile()
  remote_download(paste0(root, "/up/big.parquet"), got)
  expect_identical(readBin(got, "raw", 13e6), big)
  remote_download(paste0(root, "/up/project_id=x/model one/a b.csv"), got)
  expect_equal(readLines(got), "small")

  # Repeating the upload sends nothing new for the small files; a move and delete work.
  suppressMessages(upload_dir(dir, paste0(root, "/up")))
  move_remote(paste0(root, "/up/meta.json"), paste0(root, "/archive/meta.json"))
  expect_false(remote_exists(paste0(root, "/up/meta.json")))
  expect_true(remote_exists(paste0(root, "/archive/meta.json")))
  remove_remote(paste0(root, "/up"), recursive = TRUE)
  expect_equal(nrow(remote_files(paste0(root, "/up"))), 0)
  expect_equal(remote_files(paste0(root, "/archive"))$key, "meta.json")
})
