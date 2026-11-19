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
