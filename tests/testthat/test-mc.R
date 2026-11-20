local_mc_dir <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(minioclient.dir = file.path(dir, "mcdir"), .local_envir = env)
  file.path(dir, "mcdir", "mc")
}

test_that("an mc that is already installed is left alone", {
  path <- local_mc_dir()
  dir.create(dirname(path))
  writeLines("binary", path)
  testthat::local_mocked_bindings(download_mc_asset = function(...) stop("must not download"))
  expect_equal(ensure_mc(), path)
  expect_equal(readLines(path), "binary")
})

test_that("mc is downloaded from the GitHub release and checked", {
  path <- local_mc_dir()
  content <- tempfile()
  writeLines("pretend binary", content)
  good <- as.character(openssl::sha256(file(content)))
  asked <- NULL
  testthat::local_mocked_bindings(
    mc_platform = function() "linux-amd64",
    mc_checksums = function() c("linux-amd64" = good),
    download_mc_asset = function(url, dest) {
      asked <<- url
      file.copy(content, dest)
    }
  )
  suppressMessages(ensure_mc())
  expect_equal(asked, paste0("https://github.com/minio/mc/releases/download/", mc_release,
                             "/mc.linux-amd64.", mc_release))
  expect_true(file.exists(path))
  # Executable (the owner's execute bit; not meaningful on Windows).
  expect_true(bitwAnd(as.integer(file.info(path)$mode), 64L) > 0)
  # Once installed it is not fetched again.
  testthat::local_mocked_bindings(download_mc_asset = function(...) stop("must not download"))
  expect_no_error(ensure_mc())
})

test_that("a download that does not match the pinned checksum is removed", {
  path <- local_mc_dir()
  testthat::local_mocked_bindings(
    mc_platform = function() "linux-amd64",
    mc_checksums = function() c("linux-amd64" = strrep("0", 64)),
    download_mc_asset = function(url, dest) writeLines("tampered", dest)
  )
  expect_error(suppressMessages(ensure_mc()), "does not match its pinned checksum")
  expect_false(file.exists(path))
})

test_that("a system without a build says where to put mc", {
  path <- local_mc_dir()
  testthat::local_mocked_bindings(mc_platform = function() "windows-amd64")
  expect_error(ensure_mc(), "no mc build")
})

test_that("every supported build has a pinned checksum", {
  expect_setequal(names(mc_checksums()),
                  c("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64"))
  expect_true(all(grepl("^[0-9a-f]{64}$", mc_checksums())))
})

test_that("the install-mc action and ensure_mc() pin the same release", {
  path <- test_path("..", "..", ".github", "actions", "install-mc", "action.yml")
  skip_if_not(file.exists(path), "not running inside the repository")
  action <- suppressWarnings(yaml::read_yaml(path))
  expect_equal(action$inputs$release$default, mc_release)
  expect_equal(action$inputs$sha256$default, unname(mc_checksums()["linux-amd64"]))
})
