test_that("remote_to_s3() swaps the alias for s3://", {
  expect_equal(remote_to_s3(c("main/b/x.parquet", "main/b/y.parquet")),
               c("s3://b/x.parquet", "s3://b/y.parquet"))
  expect_error(remote_to_s3("other/b/x.parquet"), "alias")
})

test_that("upload_dir() copies a folder locally in a dry run", {
  dir <- withr::local_tempdir()
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = dir)
  from <- withr::local_tempdir()
  dir.create(file.path(from, "a=1"))
  writeLines("x", file.path(from, "a=1", "f.parquet"))
  expect_message(upload_dir(from, "main/bucket/parquet"), "DRY RUN")
  expect_true(file.exists(file.path(dir, "main/bucket/parquet/a=1/f.parquet")))
})

test_that("moves and deletes only log in a dry run", {
  withr::local_envvar(DRY_RUN = "true")
  expect_message(move_remote("main/b/x", "main/b/y"), "would move")
  expect_message(remove_remote("main/b/x"), "would delete")
})

test_that("upload_file() copies locally in a dry run", {
  dir <- withr::local_tempdir()
  withr::local_envvar(DRY_RUN = "true", DRY_RUN_DIR = dir)
  from <- withr::local_tempfile(lines = "x,y")
  expect_message(dest <- upload_file(from, "main/bucket/targets/t.csv"), "DRY RUN")
  expect_equal(dest, file.path(dir, "main/bucket/targets/t.csv"))
  expect_equal(readLines(dest), "x,y")
  expect_error(upload_file("missing.csv", "main/bucket/t.csv"), "does not exist")
})

test_that("remote paths split into alias, bucket and key", {
  expect_equal(parse_remote("main/bkt/a/b=1/c.parquet"),
               list(alias = "main", bucket = "bkt", key = "a/b=1/c.parquet"))
  expect_equal(parse_remote("main/bkt")$key, "")
  expect_error(parse_remote("bkt"), "not a remote path")
  expect_equal(folder_prefix("forecasts/parquet"), "forecasts/parquet/")
  expect_equal(folder_prefix("forecasts/parquet//"), "forecasts/parquet/")
  expect_equal(folder_prefix(""), "")
})

test_that("remote_files() lists a folder, all its pages, and not its look-alikes", {
  fake <- local_fake_s3(page_size = 2)
  for (key in c("f/parquet/a.parquet", "f/parquet/sub/b.parquet", "f/parquet/c.parquet",
                "f/parquet-old/x.parquet", "f/parquet/folder/")) {
    fake_put(fake, "bkt", key)
  }
  files <- remote_files("main/bkt/f/parquet")
  expect_equal(files$key, c("a.parquet", "c.parquet", "sub/b.parquet"))
  expect_equal(files$path, paste0("main/bkt/f/parquet/", files$key))
  expect_equal(files$bytes, c(1, 1, 1))
  expect_true(all(nzchar(files$etag)))
  # Four keys under the folder (one a folder marker), two to a page: two requests.
  expect_equal(sum(fake_calls(fake) == "list_objects_v2"), 2)
  expect_equal(nrow(remote_files("main/bkt/nothing")), 0)
  expect_named(remote_files("main/bkt/nothing"), c("path", "key", "bytes", "etag"))
})

test_that("remote_exists() is FALSE only for a missing object, and errors otherwise", {
  fake <- local_fake_s3()
  fake_put(fake, "bkt", "m/manifest.csv")
  expect_true(remote_exists("main/bkt/m/manifest.csv"))
  expect_false(remote_exists("main/bkt/m/other.csv"))

  fake_hook(fake, "head_object", function(args) {
    stop(structure(class = c("paws_error", "http_403", "http_error", "error", "condition"),
                   list(message = "Forbidden", call = NULL)))
  })
  expect_error(remote_exists("main/bkt/m/manifest.csv"), "Forbidden")
})

test_that("remote_download() writes the object to a file", {
  fake <- local_fake_s3()
  fake_put(fake, "bkt", "t/x.csv", "a,b\n1,2\n")
  dest <- file.path(withr::local_tempdir(), "deeper", "x.csv")
  expect_equal(remote_download("main/bkt/t/x.csv", dest), dest, ignore_attr = TRUE)
  expect_equal(readLines(dest), c("a,b", "1,2"))
  expect_error(remote_download("main/bkt/t/missing.csv", dest), "NoSuchKey")
})

test_that("a client must be connected before it is used", {
  expect_error(remote_files("nosuchalias/bkt/x"), "remote_connect")
})

test_that("remote_connect() builds a client for the store's endpoint and region", {
  seen <- NULL
  testthat::local_mocked_bindings(s3_client = function(endpoint, region, key, secret, anonymous) {
    seen <<- list(endpoint = endpoint, region = region, key = key, anonymous = anonymous)
    "client"
  })
  withr::defer(rm(list = c("main", "pub"), envir = remote_clients))
  cfg <- test_config()
  cfg$endpoint <- "s3.us-east-005.backblazeb2.com"
  withr::local_envvar(S3_ACCESS_KEY_ID = "id", S3_SECRET_ACCESS_KEY = "secret")
  expect_equal(remote_connect(cfg, "main"), "main")
  expect_equal(seen, list(endpoint = "s3.us-east-005.backblazeb2.com", region = "us-east-005",
                          key = "id", anonymous = FALSE))
  remote_connect(cfg, "main", alias = "pub", anonymous = TRUE)
  expect_true(seen$anonymous)
  expect_equal(seen$key, "")
  expect_equal(remote_clients[["pub"]], "client")
})

test_that("content types follow the file type", {
  expect_equal(guess_content_type("a/model.json"), "application/json")
  expect_equal(guess_content_type("t.csv"), "text/csv")
  expect_equal(guess_content_type("t.csv.gz"), "application/gzip")
  expect_equal(guess_content_type("data_0.parquet"), "application/octet-stream")
})

test_that("a small file is uploaded in one request", {
  fake <- local_fake_s3()
  from <- withr::local_tempfile(lines = c("x", "y"), fileext = ".csv")
  remote_put_file(from, "main/bkt/t/x.csv")
  expect_equal(fake_calls(fake), "put_object")
  expect_equal(fake_keys(fake, "bkt"), "t/x.csv")
  dest <- withr::local_tempfile()
  remote_download("main/bkt/t/x.csv", dest)
  expect_equal(readLines(dest), c("x", "y"))
})

test_that("a large file is uploaded in parts, in order and whole", {
  fake <- local_fake_s3()
  # A part size under S3's 5 MiB minimum is raised to it: 12 MB goes up as 5 + 5 + 2 MiB-ish.
  withr::local_options(challengeci.multipart_threshold = 1e6, challengeci.part_size = 1e6)
  from <- withr::local_tempfile(fileext = ".parquet")
  body <- as.raw(rep(0:255, length.out = 12e6))
  writeBin(body, from)
  remote_put_file(from, "main/bkt/big/data_0.parquet")
  expect_equal(fake_calls(fake), c("create_multipart_upload", rep("upload_part", 3),
                                   "complete_multipart_upload"))
  dest <- withr::local_tempfile()
  remote_download("main/bkt/big/data_0.parquet", dest)
  expect_identical(readBin(dest, "raw", 13e6), body)
})

test_that("a failed multipart upload is aborted, not left behind", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.multipart_threshold = 1e6, challengeci.part_size = 1e6)
  fake_hook(fake, "upload_part", function(args) if (args$PartNumber == 2) stop("connection reset"))
  from <- withr::local_tempfile()
  writeBin(raw(12e6), from)
  # (A reset connection is retried first, so there are retry messages before the error.)
  suppressMessages(expect_error(remote_put_file(from, "main/bkt/big/x.bin"), "connection reset"))
  expect_true("abort_multipart_upload" %in% fake_calls(fake))
  expect_false("complete_multipart_upload" %in% fake_calls(fake))
  expect_length(fake_keys(fake, "bkt"), 0)
})

local_folder <- function(files, env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  for (f in names(files)) {
    dir.create(dirname(file.path(dir, f)), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[f]], file.path(dir, f))
  }
  dir
}

test_that("upload_dir() uploads a folder, then only what changed", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.upload_workers = 1)
  fake_put(fake, "bkt", "dest/other.txt", "kept\n")
  dir <- local_folder(list("a=1/f.parquet" = "one", "b.json" = "{}", "a=1/g.parquet" = "two"))

  suppressMessages(upload_dir(dir, "main/bkt/dest"))
  expect_equal(fake_keys(fake, "bkt", "dest/"),
               c("dest/a=1/f.parquet", "dest/a=1/g.parquet", "dest/b.json", "dest/other.txt"))
  expect_equal(sum(fake_calls(fake) == "put_object"), 3)

  # Unchanged files are not sent again; a changed one is.
  suppressMessages(upload_dir(dir, "main/bkt/dest/"))
  expect_equal(sum(fake_calls(fake) == "put_object"), 3)
  writeLines("three", file.path(dir, "b.json"))
  suppressMessages(upload_dir(dir, "main/bkt/dest"))
  expect_equal(sum(fake_calls(fake) == "put_object"), 4)
  dest <- withr::local_tempfile()
  remote_download("main/bkt/dest/b.json", dest)
  expect_equal(readLines(dest), "three")
  # The other remote file was left alone.
  remote_download("main/bkt/dest/other.txt", dest)
  expect_equal(readLines(dest), "kept")
})

test_that("upload workers are capped where the parallel package would refuse more", {
  withr::local_options(challengeci.upload_workers = 4)
  withr::local_envvar(`_R_CHECK_LIMIT_CORES_` = "")
  expect_equal(upload_workers(), 4)
  withr::local_envvar(`_R_CHECK_LIMIT_CORES_` = "false")
  expect_equal(upload_workers(), 4)
  for (setting in c("TRUE", "true", "warn")) {
    withr::local_envvar(`_R_CHECK_LIMIT_CORES_` = setting)
    expect_equal(upload_workers(), 2)
  }
  withr::local_options(challengeci.upload_workers = 1)
  expect_equal(upload_workers(), 1)
})

test_that("upload_dir() with several workers uploads everything", {
  skip_on_os("windows")
  # Forked workers cannot share the in-memory fake, so each upload writes into a
  # real folder instead.
  sent <- withr::local_tempdir()
  testthat::local_mocked_bindings(
    remote_files = function(path) tibble::tibble(path = character(), key = character(),
                                                 bytes = numeric(), etag = character()),
    remote_put_file = function(from, to) {
      file.copy(from, file.path(sent, gsub("/", "_", to)))
      invisible(to)
    }
  )
  withr::local_options(challengeci.upload_workers = 3)
  dir <- local_folder(stats::setNames(as.list(letters[1:9]), paste0("p/", letters[1:9], ".txt")))
  suppressMessages(upload_dir(dir, "main/bkt/many"))
  expect_length(list.files(sent), 9)
  expect_true("main_bkt_many_p_c.txt" %in% list.files(sent))
})

test_that("upload_dir() reports the files that did not upload", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.upload_workers = 1)
  fake_hook(fake, "put_object", function(args) if (grepl("bad", args$Key)) stop("denied"))
  dir <- local_folder(list("good.txt" = "1", "bad.txt" = "2"))
  expect_error(suppressMessages(upload_dir(dir, "main/bkt/d")), "bad.txt: denied")
  expect_equal(fake_keys(fake, "bkt", "d/"), "d/good.txt")
})

test_that("move_remote() copies within a store, then deletes the source", {
  fake <- local_fake_s3()
  fake_put(fake, "bkt", "parquet/m/a.parquet", "data")
  move_remote("main/bkt/parquet/m/a.parquet", "main/bkt/archive/m/a.parquet")
  expect_equal(fake_keys(fake, "bkt"), "archive/m/a.parquet")
  expect_equal(fake_calls(fake), c("copy_object", "delete_object"))
  expect_error(move_remote("main/bkt/x", "other/bkt/x"), "within one store")
})

test_that("remove_remote() deletes one object or a whole folder in batches", {
  fake <- local_fake_s3()
  fake_put(fake, "bkt", "keep/a")
  fake_put(fake, "bkt", "one")
  remove_remote("main/bkt/one")
  expect_equal(fake_keys(fake, "bkt"), "keep/a")

  for (i in 1:2300) fake_put(fake, "bkt", sprintf("scratch/f%04d", i), "z")
  remove_remote("main/bkt/scratch", recursive = TRUE)
  expect_equal(fake_keys(fake, "bkt"), "keep/a")
  expect_equal(sum(fake_calls(fake) == "delete_objects"), 3)   # 1000 + 1000 + 300
})

# Transient failures: a store that answers 503 for a while --------------------------------

# Make `name` fail with `error` for its first `n` calls, then work.
fail_first <- function(fake, name, n, error = paws_503) {
  failures <- 0
  fake_hook(fake, name, function(args) {
    if (failures < n) {
      failures <<- failures + 1
      stop(error())
    }
  })
}

test_that("which S3 errors are worth another attempt", {
  yes <- list(
    paws_503(), paws_http_error(500, "Internal"), paws_http_error(502, "Bad gateway"),
    paws_http_error(504, "Timeout"), paws_http_error(429, "Slow down"),
    paws_http_error(400, "RequestTimeout", "RequestTimeout"),
    structure(class = c("paws_error", "error", "condition"),
              list(message = "x", call = NULL, error_response = list(Code = "SlowDown"))),
    simpleError("Failed to connect to s3.us-east-005.backblazeb2.com port 443"),
    simpleError("Connection reset by peer"), simpleError("Could not resolve host: x.org"),
    simpleError("Timeout was reached")
  )
  no <- list(
    paws_http_error(403, "Access Denied"), paws_http_error(404, "NoSuchKey"),
    paws_http_error(400, "EntityTooSmall"), paws_http_error(412, "PreconditionFailed"),
    simpleError("object not found"), simpleError("arguments imply differing number of rows")
  )
  for (e in yes) expect_true(is_transient_s3_error(e), info = conditionMessage(e))
  for (e in no) expect_false(is_transient_s3_error(e), info = conditionMessage(e))
  # A stage's own message about an S3 failure counts too.
  expect_true(looks_transient(simpleError("1 file did not upload: x.parquet: ServiceUnavailable (HTTP 503).")))
  expect_false(looks_transient(simpleError("Baselines failed: no targets")))
})

test_that("an upload survives a store that answers 503 a few times", {
  fake <- local_fake_s3()
  fail_first(fake, "put_object", 2)
  from <- withr::local_tempfile(lines = "x", fileext = ".csv")
  expect_message(remote_put_file(from, "main/bkt/t/x.csv"), "retrying")
  expect_equal(sum(fake_calls(fake) == "put_object"), 3)
  expect_equal(fake_keys(fake, "bkt"), "t/x.csv")
})

test_that("an upload that keeps getting 503 fails with that error after the attempts", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.s3_retries = 3)
  fail_first(fake, "put_object", Inf)
  from <- withr::local_tempfile(lines = "x", fileext = ".csv")
  err <- suppressMessages(expect_error(remote_put_file(from, "main/bkt/t/x.csv"), "HTTP 503"))
  expect_s3_class(err, "http_503")
  expect_equal(sum(fake_calls(fake) == "put_object"), 3)
})

test_that("a refusal is not retried", {
  fake <- local_fake_s3()
  fail_first(fake, "put_object", Inf, error = function() paws_http_error(403, "Access Denied"))
  from <- withr::local_tempfile(lines = "x", fileext = ".csv")
  expect_error(remote_put_file(from, "main/bkt/t/x.csv"), "Access Denied")
  expect_equal(sum(fake_calls(fake) == "put_object"), 1)
})

test_that("only the part that failed is sent again", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.multipart_threshold = 1e6, challengeci.part_size = 1e6)
  failures <- 0
  fake_hook(fake, "upload_part", function(args) {
    if (args$PartNumber == 2 && failures < 1) {
      failures <<- failures + 1
      stop(paws_503())
    }
  })
  from <- withr::local_tempfile(fileext = ".parquet")
  body <- as.raw(rep(0:255, length.out = 12e6))
  writeBin(body, from)
  suppressMessages(remote_put_file(from, "main/bkt/big/data_0.parquet"))
  expect_equal(fake_calls(fake), c("create_multipart_upload", "upload_part", "upload_part",
                                   "upload_part", "upload_part", "complete_multipart_upload"))
  dest <- withr::local_tempfile()
  remote_download("main/bkt/big/data_0.parquet", dest)
  expect_identical(readBin(dest, "raw", 13e6), body)
})

test_that("listing, reading and checking an object survive a 503 too, and a 404 still means missing", {
  fake <- local_fake_s3()
  fake_put(fake, "bkt", "f/a.txt", "hello\n")
  fail_first(fake, "list_objects_v2", 1)
  expect_message(files <- remote_files("main/bkt/f"), "retrying")
  expect_equal(files$key, "a.txt")

  fail_first(fake, "get_object", 2)
  dest <- withr::local_tempfile()
  suppressMessages(remote_download("main/bkt/f/a.txt", dest))
  expect_equal(readLines(dest), "hello")

  fail_first(fake, "head_object", 1)
  expect_true(suppressMessages(remote_exists("main/bkt/f/a.txt")))
  # A missing object is still FALSE, at once, not a failure to retry.
  fake_hook(fake, "head_object", function(args) NULL)
  before <- sum(fake_calls(fake) == "head_object")
  expect_false(remote_exists("main/bkt/f/nothing.txt"))
  expect_equal(sum(fake_calls(fake) == "head_object") - before, 1)
})

test_that("a folder upload retries the file that got a 503 and loses nothing", {
  fake <- local_fake_s3()
  withr::local_options(challengeci.upload_workers = 1)
  fail_first(fake, "put_object", 1)
  dir <- local_folder(list("a/f.parquet" = "one", "b.json" = "{}"))
  suppressMessages(upload_dir(dir, "main/bkt/dest"))
  expect_equal(fake_keys(fake, "bkt", "dest/"), c("dest/a/f.parquet", "dest/b.json"))
})
