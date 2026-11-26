# The trigger templates in inst/workflows are valid, and the pipeline runs the
# stages in the order that makes the dashboard see a day's forecasts.

read_workflow <- function(path) suppressWarnings(yaml::read_yaml(path))
# YAML's `on` key can be read as the logical TRUE.
triggers <- function(wf) wf[["on"]] %||% wf[["TRUE"]]

workflows_dir <- function(...) {
  path <- test_path("..", "..", ...)
  skip_if_not(dir.exists(path), "not running inside the repository")
  path
}

test_that("every trigger template is valid YAML and calls an engine workflow", {
  dir <- workflows_dir("inst", "workflows")
  for (f in list.files(dir, "\\.ya?ml$", full.names = TRUE)) {
    wf <- read_workflow(f)
    expect_true(!is.null(triggers(wf)), info = f)
    uses <- unlist(lapply(wf$jobs, function(j) j$uses))
    # Every job that calls a reusable workflow calls the engine's, at @main (the
    # release workflow rewrites that to the tag).
    expect_true(all(grepl("^eco4cast/challenge-ci/\\.github/(workflows/_[a-z0-9_-]+\\.yaml)@main$", uses)),
                info = f)
  }
})

# The jobs that must finish before `job`, directly or not.
ancestors <- function(jobs, job) {
  needs <- as.character(unlist(jobs[[job]]$needs))
  unique(c(needs, unlist(lapply(needs, function(n) ancestors(jobs, n)))))
}

test_that("the pipeline runs the stages in order, and a failure does not stop the rest", {
  wf <- read_workflow(file.path(workflows_dir("inst", "workflows"), "pipeline.yaml"))
  jobs <- wf$jobs
  stage_of <- function(job) sub("^.*/_([a-z0-9_-]+)\\.yaml@main$", "\\1", jobs[[job]]$uses)
  by_stage <- function(stage) names(jobs)[vapply(names(jobs), function(j) {
    !is.null(jobs[[j]]$uses) && identical(stage_of(j), stage)
  }, logical(1))]
  one <- function(stage) {
    found <- by_stage(stage)
    expect_length(found, if (stage == "baselines") 2 else 1)
    found
  }
  expect_setequal(c(by_stage("targets"), by_stage("baselines"), by_stage("submissions"),
                    by_stage("bundling"), by_stage("scoring"), by_stage("dashboard"),
                    by_stage("catalog")), setdiff(names(jobs), "calendar"))

  before <- function(first, second) {
    for (b in one(second)) for (a in one(first)) expect_true(a %in% ancestors(jobs, b), info = paste(a, "before", b))
  }
  before("targets", "baselines")
  before("baselines", "submissions")
  before("submissions", "bundling")
  before("bundling", "scoring")
  before("scoring", "dashboard")
  before("scoring", "catalog")
  # The weekly baselines are made before the day's submissions are read, only on Sunday.
  expect_true("baselines_weekly" %in% ancestors(jobs, "submissions"))
  expect_match(jobs$baselines_weekly$`if`, "sunday == 'true'", fixed = TRUE)
  expect_equal(jobs$baselines_weekly$with$schedule, "weekly")
  expect_equal(jobs$baselines$with$schedule, "daily")

  # Every stage after the first runs unless the run was cancelled, so one failing stage
  # (one bad repository, say) still leaves a dashboard built from what exists.
  for (job in setdiff(names(jobs), c("calendar", "targets"))) {
    expect_match(jobs[[job]]$`if`, "!cancelled()", fixed = TRUE, info = job)
  }
})

test_that("the pipeline passes only inputs its stages declare, and its cron avoids the hour", {
  dir <- workflows_dir("inst", "workflows")
  wf <- read_workflow(file.path(dir, "pipeline.yaml"))
  engine <- workflows_dir(".github", "workflows")
  for (job in names(wf$jobs)) {
    j <- wf$jobs[[job]]
    if (is.null(j$uses)) next
    called <- read_workflow(file.path(engine, sub("^.*/(_[a-z0-9_-]+\\.yaml)@main$", "\\1", j$uses)))
    declared <- names(triggers(called)$workflow_call$inputs)
    expect_true(all(names(j$with) %in% declared), info = job)
    expect_identical(j$secrets, "inherit", info = job)
  }
  cron <- triggers(wf)$schedule[[1]]$cron
  expect_length(cron, 1)
  # Not on the hour: GitHub says the start of every hour is a high-load time.
  expect_false(startsWith(cron, "0 "))
  expect_equal(wf$permissions$contents, "write")
  expect_false(wf$concurrency$`cancel-in-progress`)
})
