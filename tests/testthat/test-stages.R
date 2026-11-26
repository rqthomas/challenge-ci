test_that("run_stage() names the stages when it gets none or an unknown one", {
  expect_error(run_stage(character()), "Name a stage")
  expect_error(run_stage("frobnicate"), "Unknown stage")
})

test_that("run_each() runs every item and fails at the end", {
  seen <- character()
  expect_error(
    run_each(c("a", "b", "c"), function(x) {
      seen <<- c(seen, x)
      if (x == "b") stop("broken")
    }, "Job"),
    "Job failed"
  )
  expect_equal(seen, c("a", "b", "c"))
})

workflow_dir <- function(...) test_path("..", "..", ".github", ...)

test_that("reusable workflows and actions refer to the engine by full name", {
  skip_if_not(dir.exists(workflow_dir()), "not running inside the repository")
  files <- c(list.files(workflow_dir("workflows"), "^_.*\\.yaml$", full.names = TRUE),
             list.files(workflow_dir("actions"), "action\\.yml$", recursive = TRUE,
                        full.names = TRUE))
  for (f in files) {
    uses <- grep("uses:", readLines(f), value = TRUE)
    expect_false(any(grepl("uses: \\./", uses)), info = f)
  }
})

test_that("every trigger template calls a reusable workflow that exists", {
  skip_if_not(dir.exists(workflow_dir()), "not running inside the repository")
  triggers <- list.files(system.file("workflows", package = "challengeci"), full.names = TRUE)
  skip_if(length(triggers) == 0)
  for (f in triggers) {
    called <- sub(".*/\\.github/workflows/([^@]+)@.*", "\\1",
                  grep("uses: .*challenge-ci", readLines(f), value = TRUE))
    expect_true(all(file.exists(workflow_dir("workflows", called))), info = f)
  }
})

test_that("run_each() gives a transiently failed item one more attempt, and only that", {
  withr::local_options(challengeci.stage_retry_wait = 0)
  # Fails once with a 503, then works: no error, the item ran twice.
  runs <- character()
  flaky <- function(item) {
    runs <<- c(runs, item)
    if (item == "b" && sum(runs == "b") == 1) stop("1 file did not upload: x: ServiceUnavailable (HTTP 503).")
  }
  suppressMessages(run_each(c("a", "b", "c"), flaky, "Baselines"))
  expect_equal(runs, c("a", "b", "c", "b"))

  # A failure that another attempt will not fix is not repeated, and the stage fails.
  runs <- character()
  broken <- function(item) {
    runs <<- c(runs, item)
    if (item == "b") stop("no targets for this group")
  }
  expect_error(suppressMessages(run_each(c("a", "b"), broken, "Baselines")), "failed for \"b\"")
  expect_equal(runs, c("a", "b"))

  # Still 503 on the second attempt: it fails, after exactly two attempts.
  runs <- character()
  down <- function(item) {
    runs <<- c(runs, item)
    stop("ServiceUnavailable (HTTP 503)")
  }
  expect_error(suppressMessages(run_each("a", down, "Baselines")), "failed for \"a\"")
  expect_equal(runs, c("a", "a"))
})
