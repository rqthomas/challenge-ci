# The git steps of the catalog workflow (.github/actions/catalog-clone and
# catalog-push), run against throwaway local repositories: no network, no token.

actions_dir <- function(...) test_path("..", "..", ".github", "actions", ...)

skip_without_git_actions <- function() {
  skip_on_os("windows")
  skip_if(Sys.which("git") == "", "git is not installed")
  skip_if_not(file.exists(actions_dir("catalog-clone", "clone.sh")), "not running inside the repository")
}

# A bare repository whose default branch `main` holds the challenge's code.
code_repo <- function(env = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = env)
  bare <- file.path(root, "remote.git")
  work <- file.path(root, "work")
  git <- function(...) system2("git", c(...), stdout = FALSE, stderr = FALSE)
  git("init", "-q", "--bare", "-b", "main", bare)
  git("init", "-q", "-b", "main", work)
  writeLines("code", file.path(work, "code.txt"))
  git("-C", work, "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A")
  git("-C", work, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "code")
  git("-C", work, "push", "-q", bare, "main")
  bare
}

run_script <- function(script, remote, dir, branch = "") {
  withr::local_envvar(c(REPO = "o/r", BRANCH = branch, DIR = dir, TOKEN = "unused",
                        CATALOG_REMOTE_URL = remote))
  out <- suppressWarnings(system2("bash", script, stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = out)
}
clone <- function(...) run_script(actions_dir("catalog-clone", "clone.sh"), ...)
push <- function(...) run_script(actions_dir("catalog-push", "push.sh"), ...)

branches <- function(remote) {
  out <- system2("git", c("-C", remote, "for-each-ref", "--format=%\\(refname:short\\)", "refs/heads"),
                 stdout = TRUE)
  sort(out)
}
files_on <- function(remote, branch) {
  system2("git", c("-C", remote, "ls-tree", "-r", "--name-only", branch), stdout = TRUE)
}

test_that("a catalog branch that does not exist yet is created empty, apart from the code", {
  skip_without_git_actions()
  remote <- code_repo()
  dir <- file.path(withr::local_tempdir(), "catalog")
  expect_equal(clone(remote, dir, "catalog")$status, 0)
  # Nothing of the code is in the new branch's folder.
  expect_false(file.exists(file.path(dir, "code.txt")))
  dir.create(file.path(dir, "forecasts"))
  writeLines("{}", file.path(dir, "catalog.json"))
  writeLines("{}", file.path(dir, "forecasts", "collection.json"))

  expect_equal(push(remote, dir, "catalog")$status, 0)
  expect_equal(branches(remote), c("catalog", "main"))
  expect_setequal(files_on(remote, "catalog"), c("catalog.json", "forecasts/collection.json"))
  # The code branch is untouched.
  expect_equal(files_on(remote, "main"), "code.txt")
})

test_that("an existing catalog branch is updated, and an unchanged catalog adds nothing", {
  skip_without_git_actions()
  remote <- code_repo()
  first <- file.path(withr::local_tempdir(), "catalog")
  clone(remote, first, "catalog")
  writeLines("one", file.path(first, "catalog.json"))
  push(remote, first, "catalog")

  second <- file.path(withr::local_tempdir(), "catalog")
  expect_equal(clone(remote, second, "catalog")$status, 0)
  expect_equal(readLines(file.path(second, "catalog.json")), "one")
  writeLines("two", file.path(second, "catalog.json"))
  expect_equal(push(remote, second, "catalog")$status, 0)
  commits <- function() length(system2("git", c("-C", remote, "rev-list", "catalog"), stdout = TRUE))
  expect_equal(commits(), 2)

  # Nothing changed: no new commit, and not an error.
  third <- file.path(withr::local_tempdir(), "catalog")
  clone(remote, third, "catalog")
  result <- push(remote, third, "catalog")
  expect_equal(result$status, 0)
  expect_match(paste(result$out, collapse = "\n"), "nothing to commit")
  expect_equal(commits(), 2)
})

test_that("without a branch the repository's default branch is used", {
  skip_without_git_actions()
  remote <- code_repo()
  dir <- file.path(withr::local_tempdir(), "catalog")
  expect_equal(clone(remote, dir)$status, 0)
  expect_true(file.exists(file.path(dir, "code.txt")))
  writeLines("{}", file.path(dir, "catalog.json"))
  expect_equal(push(remote, dir)$status, 0)
  expect_setequal(files_on(remote, "main"), c("code.txt", "catalog.json"))
})

test_that("a push made since the clone is taken in, not overwritten", {
  skip_without_git_actions()
  remote <- code_repo()
  mine <- file.path(withr::local_tempdir(), "catalog")
  other <- file.path(withr::local_tempdir(), "catalog")
  clone(remote, mine, "catalog")
  clone(remote, other, "catalog")
  writeLines("a", file.path(other, "a.json"))
  push(remote, other, "catalog")
  # `mine` was cloned before that push (and the branch did not exist then).
  writeLines("b", file.path(mine, "b.json"))
  result <- push(remote, mine, "catalog")
  expect_equal(result$status, 0)
  expect_setequal(files_on(remote, "catalog"), c("a.json", "b.json"))
})

test_that("an unreachable repository stops the run instead of starting an empty branch", {
  skip_without_git_actions()
  gone <- file.path(withr::local_tempdir(), "nothing-here.git")
  dir <- file.path(withr::local_tempdir(), "catalog")
  result <- clone(gone, dir, "catalog")
  expect_true(result$status != 0)
  expect_false(dir.exists(dir))
})
