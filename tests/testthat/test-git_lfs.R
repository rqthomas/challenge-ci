# Git LFS pointers (Hugging Face stores *.gz, *.parquet and anything over 10 MB
# this way): the pointer is replaced by the file it stands for.

lfs_pointer_text <- function(content) {
  oid <- as.vector(as.character(openssl::sha256(charToRaw(content))))
  c("version https://git-lfs.github.com/spec/v1", paste0("oid sha256:", oid),
    paste0("size ", nchar(content, "bytes")))
}

test_that("a Git LFS pointer is recognised and read", {
  content <- "a,b\n1,2\n"
  pointer <- withr::local_tempfile()
  writeLines(lfs_pointer_text(content), pointer)
  info <- lfs_pointer(pointer)
  expect_equal(info$size, 8)
  expect_match(info$oid, "^[0-9a-f]{64}$")
  expect_true(is_lfs_pointer(pointer))

  csv <- withr::local_tempfile()
  writeLines(c("a,b", "1,2"), csv)
  expect_null(lfs_pointer(csv))
  # Not a pointer: a missing or malformed oid or size.
  bad <- withr::local_tempfile()
  writeLines(c("version https://git-lfs.github.com/spec/v1", "oid sha256:abc", "size 123"), bad)
  expect_null(lfs_pointer(bad))
  writeLines(c("version https://git-lfs.github.com/spec/v1", lfs_pointer_text(content)[2]), bad)
  expect_null(lfs_pointer(bad))
})

mock_lfs_host <- function(content, href = "https://cdn.example.org/file", error = NULL,
                          served = content, env = parent.frame()) {
  seen <- new.env()
  httr2::local_mocked_responses(function(req) {
    seen$batch <- req
    if (!is.null(error)) {
      return(httr2::response_json(status_code = 404, body = list(message = error)))
    }
    object <- list(oid = "x", size = 1,
                   actions = list(download = list(href = href, header = list(`X-Token` = "t"))))
    httr2::response_json(body = list(objects = list(object)))
  }, env = env)
  testthat::local_mocked_bindings(
    lfs_fetch_file = function(href, headers, path, timeout) {
      seen$download <- list(href = href, headers = headers)
      writeChar(served, path, eos = NULL)
    },
    .env = env
  )
  seen
}

test_that("a pointer is resolved through the host's Git LFS batch API", {
  content <- "a,b\n1,2\n3,4\n"
  pointer <- list(oid = as.vector(as.character(openssl::sha256(charToRaw(content)))),
                  size = nchar(content, "bytes"))
  seen <- mock_lfs_host(content)
  dest <- withr::local_tempfile()
  writeLines("pointer", dest)
  git_lfs_download("https://huggingface.co/datasets/o/n.git", pointer, dest)
  expect_equal(readChar(dest, 100), content)
  # The batch request asked to download this object, as the LFS API wants it.
  expect_match(seen$batch$url, "^https://huggingface.co/datasets/o/n.git/info/lfs/objects/batch$")
  body <- seen$batch$body$data
  expect_equal(body$operation, "download")
  expect_equal(body$objects[[1]]$oid, pointer$oid)
  expect_match(seen$batch$headers$Accept, "git-lfs")
  # Headers the host asked for go with the download; its address is used as given.
  expect_equal(seen$download$href, "https://cdn.example.org/file")
  expect_equal(seen$download$headers[["X-Token"]], "t")
})

test_that("a Git LFS file that does not match its pointer, or cannot be served, is an error", {
  content <- "a,b\n1,2\n"
  pointer <- list(oid = as.vector(as.character(openssl::sha256(charToRaw(content)))),
                  size = nchar(content, "bytes"))
  dest <- withr::local_tempfile()
  writeLines("pointer", dest)

  mock_lfs_host(content, served = "a,b\n9,9\n")        # same size, different bytes
  expect_error(git_lfs_download("https://host/o/n.git", pointer, dest), "did not match")
  expect_equal(readLines(dest), "pointer")             # the pointer is left alone

  mock_lfs_host(content, href = "http://cdn.example.org/file")
  expect_error(git_lfs_download("https://host/o/n.git", pointer, dest), "not https")

  mock_lfs_host(content, error = "Object does not exist")
  expect_error(git_lfs_download("https://host/o/n.git", pointer, dest), "Object does not exist")

  expect_error(git_lfs_download(NULL, pointer, dest), "without the repository address")
})

test_that("git_blob() replaces a pointer unless the file is over the size limit", {
  skip_if(!nzchar(Sys.which("git")), "git is not installed")
  content <- "a,b\n1,2\n"
  src <- withr::local_tempdir()
  git <- function(...) system2("git", c("-C", src, "-c", "user.name=t", "-c", "user.email=t@t", ...),
                               stdout = FALSE, stderr = FALSE)
  git("init", "-q", "-b", "main")
  git("config", "uploadpack.allowFilter", "true")
  git("config", "uploadpack.allowAnySHA1InWant", "true")
  writeLines(lfs_pointer_text(content), file.path(src, "forecast.csv.gz"))
  git("add", ".")
  git("commit", "-q", "-m", "first")

  withr::local_options(challengeci.git_protocols = c("https", "file"))
  handle <- git_open(paste0("file://", src))
  withr::defer(git_close(handle))
  sha <- git_tree(handle)$sha
  fetched <- NULL
  testthat::local_mocked_bindings(
    git_lfs_download = function(url, pointer, dest, timeout = 300) {
      fetched <<- list(url = url, size = pointer$size)
      writeChar(content, dest, eos = NULL)
    }
  )
  dest <- withr::local_tempfile()
  git_blob(handle, sha, dest)
  expect_equal(readChar(dest, 100), content)
  expect_equal(fetched$url, paste0("file://", src))

  # Over the limit: the pointer stays, so process_submission() can say why.
  fetched <- NULL
  big <- withr::local_tempfile()
  git_blob(handle, sha, big, max_bytes = 4)
  expect_null(fetched)
  expect_false(is.null(lfs_pointer(big)))
})

test_that("a pointer that was not resolved is reported with its size", {
  content <- "a,b\n1,2\n"
  path <- file.path(withr::local_tempdir(), "forecast.csv.gz")
  writeLines(lfs_pointer_text(content), path)
  res <- process_submission(path, test_config(), withr::local_tempdir(),
                            context = list(route = "repo"))
  expect_equal(res$status, "invalid")
  expect_match(res$reason, "Git LFS pointer")
  expect_match(res$reason, "host would not serve")

  res <- process_submission(path, test_config(), withr::local_tempdir(),
                            context = list(route = "repo", max_bytes = 4))
  expect_match(res$reason, "larger than")
})

test_that("Hugging Face repositories are allowed and addressed like any other host", {
  cfg <- github_cfg()
  expect_true("huggingface.co" %in% cfg$submissions$repos$allowed_hosts)
  expect_equal(normalize_repo("https://huggingface.co/datasets/owner/forecasts"),
               "huggingface.co/datasets/owner/forecasts")
  expect_equal(normalize_repo("https://huggingface.co/owner/model.git"), "huggingface.co/owner/model")
  expect_equal(repo_clone_url(cfg, "huggingface.co/datasets/owner/forecasts"),
               "https://huggingface.co/datasets/owner/forecasts.git")
})
