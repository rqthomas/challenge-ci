# The command-line entry point: every workflow job (and every local run) calls
#
#   Rscript -e 'challengeci::run_stage()' <stage> [arguments]
#
# from the root of a challenge repository, so the job runs the version of the
# package installed in its image and reads the challenge's own config.

#' Run one stage of the challenge from the command line
#'
#' Stages and their arguments:
#'
#' | Stage | Arguments | Runs |
#' |---|---|---|
#' | `submissions` | | [run_submissions()] |
#' | `bundle` | `forecasts` and/or `summaries` (default both) | [run_bundling()] |
#' | `score` | optional start date `YYYY-MM-DD` (default six months ago) | [run_scoring()] |
#' | `baselines` | `daily` or `weekly`, then optional group names | [run_baselines()] |
#' | `drivers-stage1-2` | | [download_gefs()], [update_stage2()] |
#' | `drivers-stage3` | optional `rebuild` | [download_gefs()], [update_stage3()] |
#' | `catalog` | optional catalog parts | [run_catalog()] |
#' | `dashboard` | optional output folder (default `dashboard/docs`) | [render_dashboard()] |
#' | `register` | | [run_registration()], for the issue in `ISSUE_BODY` and `ISSUE_NUMBER` |
#' | `check` | | [check_challenge_repo()] |
#'
#' Environment variables: `CHALLENGE_CONFIG` (config file), `DRY_RUN` and
#' `DRY_RUN_DIR` (see [is_dry_run()]), `VERBOSE`, and the credential variables
#' named in the config's `credentials` (see [config_defaults()]).
#'
#' When one item of a stage fails (a bundle kind, a baseline group), the others
#' still run and the stage fails at the end.
#'
#' @param args Command-line arguments: the stage name, then its arguments.
#' @return Called for its side effects; the stage's result, invisibly. Errors
#'   make `Rscript` exit with a non-zero status.
#' @export
#' @examples
#' \dontrun{
#' # From a shell, in a challenge repository:
#' #   Rscript -e 'challengeci::run_stage()' score 2025-01-01
#' #   DRY_RUN=true Rscript -e 'challengeci::run_stage()' catalog
#' }
run_stage <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) == 0) {
    cli::cli_abort("Name a stage: {.val {names(stage_runners)}}. See {.code ?run_stage}.")
  }
  stage <- args[1]
  runner <- stage_runners[[stage]]
  if (is.null(runner)) {
    cli::cli_abort("Unknown stage {.val {stage}}; one of {.val {names(stage_runners)}}.")
  }
  invisible(runner(args[-1]))
}

# Runs `fun` for each item, keeps going after a failure, and fails at the end.
run_each <- function(items, fun, what) {
  ok <- vapply(items, function(item) {
    tryCatch({
      fun(item)
      TRUE
    }, error = function(e) {
      cli::cli_alert_danger("{what} {item}: {conditionMessage(e)}")
      FALSE
    })
  }, logical(1))
  if (!all(ok)) cli::cli_abort("{what} failed for {.val {items[!ok]}}.")
  invisible(items)
}

stage_runners <- list(
  submissions = function(args) {
    run_submissions(read_config())
  },
  register = function(args) {
    cfg <- read_config()
    run_registration(cfg, body = Sys.getenv("ISSUE_BODY"),
                     number = Sys.getenv("ISSUE_NUMBER"))
  },
  bundle = function(args) {
    cfg <- read_config()
    kinds <- if (length(args) == 0) c("forecasts", "summaries") else args
    run_each(kinds, function(kind) run_bundling(cfg, kind), "Bundling")
  },
  score = function(args) {
    cfg <- read_config()
    if (length(args) == 0) run_scoring(cfg) else run_scoring(cfg, since = as.Date(args[1]))
  },
  baselines = function(args) {
    if (length(args) == 0) cli::cli_abort("Give a schedule: {.val daily} or {.val weekly}.")
    cfg <- read_config()
    groups <- if (length(args) > 1) args[-1] else names(cfg$target_groups)
    run_each(groups, function(group) run_baselines(cfg, group, schedule = args[1]), "Baselines")
  },
  `drivers-stage1-2` = function(args) {
    cfg <- read_config()
    gdalcubes::gdalcubes_options(parallel = 2 * parallel::detectCores())
    download_gefs(cfg, "stage1-stats")
    download_gefs(cfg, "stage1")
    update_stage2(cfg)
  },
  `drivers-stage3` = function(args) {
    cfg <- read_config()
    rebuild <- identical(args, "rebuild")
    gdalcubes::gdalcubes_options(parallel = 20)
    if (!rebuild) download_gefs(cfg, "pseudo")
    update_stage3(cfg, overlap_days = if (rebuild) Inf else 3)
  },
  catalog = function(args) {
    cfg <- read_config()
    if (length(args) == 0) run_catalog(cfg) else run_catalog(cfg, args)
  },
  dashboard = function(args) {
    cfg <- read_config()
    if (length(args) == 0) render_dashboard(cfg) else render_dashboard(cfg, out_dir = args[1])
  },
  check = function(args) {
    problems <- check_challenge_repo(".")
    if (nrow(problems) > 0) print(problems, n = Inf)
    if (any(problems$severity == "error")) cli::cli_abort("The challenge repository has errors.")
    cli::cli_alert_success("The challenge repository is consistent.")
    invisible(problems)
  }
)
