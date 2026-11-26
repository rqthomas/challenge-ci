# The dashboard: a Quarto site built from the template in inst/dashboard/ and
# the challenge's own content (render_dashboard()).
#
# stage_dashboard_data() runs before `quarto render`: it does every S3 query
# and writes small public JSON files (the data contract, docs/dashboard-data.md,
# built by R/dashboard_data.R). The pages read only those files, in the
# browser, so a private bucket's key never leaves the build.
#
#   meta.json                  the challenge, variables, sites, datasets, access
#   models.json                every model, for labels and filters
#   activity.json              the recent activity feed of the home page
#   leaderboard/<variable>.json  skill and CRPS by window, horizon and date
#   forecasts/<variable>__<site>.json  the latest and a scored forecast, with observations
#   targets/<variable>.json    the observations at the focal sites, for the targets page
#   models/<model_id>.json     a model's registration
#   results/<model_id>.json    what happened to each file a model submitted
#   variables.csv, sites.csv   for the pages that render tables in R

#' Dashboard settings
#'
#' Reads the `dashboard` block of the config and fills in defaults:
#' * `n_plot_sites` (2): sites per target group shown in forecast plots, taken
#'   from the start of each group's `focal_sites`.
#' * `leaderboard_max_horizon` (35): longest horizon, in days, in the
#'   leaderboards.
#' * `excluded_models`: model ids left out of the plots, per variable, plus
#'   `all` for every variable.
#' * `content_dir` (`challenge/dashboard`): the challenge's dashboard content
#'   (see [render_dashboard()]).
#' * `extra_pages`: the challenge's own pages for the navigation, each with
#'   `href` (e.g. `learn-more.qmd`) and a `title` (default: the file name).
#' * `title`, `tagline`: the site title (default: the challenge's long name)
#'   and the sentence under the home page's heading.
#' * `skill_baseline`: a model id to measure skill against for every variable
#'   (default: the group's climatology baseline, see [skill_baselines()]).
#' * `min_forecasts` (5): forecast days a model needs in a leaderboard window
#'   to be ranked.
#' * `publish_results` (`true`): publish the outcome of each submitted file on
#'   the site, which "Check my submissions" reads.
#' * `key_request_url`: where a participant asks for a read-only key when the
#'   bucket is private (default: the contact address).
#'
#' @inheritParams config_get
#' @return A list.
#' @export
dashboard_settings <- function(cfg) {
  defaults <- list(n_plot_sites = 2, leaderboard_max_horizon = 35, excluded_models = list(),
                   content_dir = file.path("challenge", "dashboard"), extra_pages = list(),
                   min_forecasts = 5, publish_results = TRUE, settle_days = 2)
  # Each setting replaces its default whole: modifyList() would merge the
  # unnamed `extra_pages` list into the empty default and lose it.
  settings <- defaults
  settings[names(cfg$dashboard)] <- cfg$dashboard
  settings
}

#' The two horizons of the leaderboard's horizon toggle
#'
#' `dashboard$horizons` lists two lead times, in days, for the leaderboard to be
#' restricted to (in addition to "all horizons"). A horizon of 7 keeps only the
#' forecasts made 7 days ahead. Not set: no toggle.
#'
#' @inheritParams config_get
#' @return A sorted numeric vector of the horizons: none, or two.
#' @export
#' @examples
#' dashboard_horizons(list(dashboard = list(horizons = c(7, 1))))
dashboard_horizons <- function(cfg) {
  horizons <- suppressWarnings(as.numeric(unlist(cfg$dashboard$horizons)))
  sort(unique(horizons[!is.na(horizons)]))
}

#' How far back the dashboard looks for a duration
#'
#' Weekly and longer variables are observed slowly, so their leaderboards
#' and forecast analysis use the last year; shorter ones use the last 30 days.
#'
#' @param duration ISO 8601 duration, e.g. `"P1D"`.
#' @return Number of days.
#' @export
#' @examples
#' dashboard_lookback_days(c("P1D", "P1W"))
dashboard_lookback_days <- function(duration) {
  seconds <- vapply(duration, function(d) as.numeric(lubridate::duration(d)), numeric(1))
  unname(ifelse(seconds >= 7 * 86400, 365, 30))
}

#' Sites shown in each target group's forecast plots
#'
#' @inheritParams config_get
#' @return A tibble with `group`, `variable`, `duration` and `site_id`: the
#'   first `n_plot_sites` of the group's `focal_sites`.
#' @export
plot_sites <- function(cfg) {
  focal_site_table(cfg, dashboard_settings(cfg)$n_plot_sites)
}

# The first `n` focal sites of every group, crossed with the group's variables.
focal_site_table <- function(cfg, n = Inf) {
  sites <- purrr::imap(cfg$target_groups, function(settings, group) {
    focal <- as.character(unlist(settings$focal_sites))
    tibble::tibble(group = group, site_id = utils::head(focal, n))
  }) |>
    purrr::list_rbind()
  dplyr::inner_join(target_variables(cfg)[c("group", "variable", "duration")], sites,
                    by = "group", relationship = "many-to-many")
}

#' Stage the data the dashboard reads
#'
#' Writes the dashboard's data contract (`docs/dashboard-data.md`) to
#' `out_dir`: JSON files the pages load in the browser, plus two CSV files for
#' the pages that render tables in R. Every bucket read happens here, with the
#' challenge's key when the bucket is private.
#'
#' @inheritParams config_get
#' @param out_dir Folder to write to.
#' @param now Time the dashboard is built; the windows are relative to it.
#' @return `out_dir`, invisibly.
#' @export
stage_dashboard_data <- function(cfg, out_dir = file.path("dashboard", "data"),
                                 now = Sys.time()) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  duckdb_connect(cfg, "main", anonymous = anonymous_reads(cfg))
  conn <- duckdbfs::cached_connection()
  settings <- dashboard_settings(cfg)
  variables <- dashboard_variables(cfg)
  project <- paste0("project_id=", cfg$project_id)

  # NULL when nothing has been bundled or scored yet (a new challenge).
  inputs <- purrr::map(rlang::set_names(unique(variables$duration)), function(duration) {
    partition <- paste0("duration=", duration)
    list(
      summaries = bucket_uri(cfg, "summaries_bucket", "bundled-summaries", project, partition) |>
        open_dataset_if_any(conn = conn),
      scores = bucket_uri(cfg, "scores_bucket", "bundled-parquet", project, partition) |>
        open_dataset_if_any(conn = conn)
    )
  })
  observations <- focal_observations(cfg)
  registered <- read_registered_models(cfg)
  stats <- dashboard_stats(cfg, conn, now)
  submissions <- NULL
  if (isTRUE(settings$publish_results)) {
    remote_connect(cfg, "main", anonymous = anonymous_reads(cfg))
    submissions <- stage_results(cfg, out_dir)
  }
  write_dashboard_data(cfg, out_dir, now, inputs, observations, registered, stats, variables,
                       conn, submissions = submissions)
  readr::write_csv(variables, file.path(out_dir, "variables.csv"))
  readr::write_csv(dashboard_sites(cfg), file.path(out_dir, "sites.csv"))
  log_step("Dashboard: data written to {.path {out_dir}}")
  invisible(out_dir)
}

# The challenge's variables with their catalog names and a dashboard `id`.
dashboard_variables <- function(cfg, metadata = read_variable_metadata(cfg)) {
  variables <- catalog_variables(cfg, metadata)
  variables$id <- dashboard_variable_id(variables$variable, variables$duration)
  variables
}

# Writes the data contract from what was read: `inputs` has, per duration, the
# `summaries` and `scores` as lazy tables (or NULL); `observations` are the
# targets at the focal sites (see focal_observations()); `submissions` the
# outcomes of submitted files from stage_results(), for the activity feed;
# `registered` the models from read_registered_models(); `stats` the headline
# numbers. No bucket is read
# here, so tests can run it on local files.
write_dashboard_data <- function(cfg, out_dir, now, inputs, observations, registered, stats,
                                 variables = dashboard_variables(cfg),
                                 conn = duckdbfs::cached_connection(), submissions = NULL) {
  settings <- dashboard_settings(cfg)
  sites <- plot_sites(cfg)
  baselines <- skill_baselines(cfg)

  scored_models <- character()
  models_by_variable <- list()
  active_models <- character()
  last_scored <- NULL
  for (duration in unique(variables$duration)) {
    log_step("Dashboard: {duration}")
    lookback <- dashboard_lookback_days(duration)
    windows <- dashboard_windows(duration)
    vars <- variables[variables$duration == duration, ]
    summaries <- inputs[[duration]]$summaries
    scores <- inputs[[duration]]$scores
    duration_sites <- dplyr::filter(sites, .data$duration == !!duration)
    latest <- if (is.null(summaries)) empty_dashboard_table("forecasts") else
      latest_forecasts(summaries, duration_sites, now, settings$settle_days)
    scored <- if (is.null(scores)) empty_dashboard_table("analysis") else
      scored_forecasts(scores, duration_sites, now, lookback)
    cells <- NULL
    if (!is.null(scores)) {
      rows <- leaderboard_rows(scores, dplyr::filter(baselines, .data$duration == !!duration),
                               now, windows, settings$leaderboard_max_horizon, conn)
      cells <- leaderboard_cells(rows, now, windows, dashboard_horizons(cfg))
    }

    for (i in seq_len(nrow(vars))) {
      v <- vars[i, ]
      excluded <- unique(unlist(settings$excluded_models[c("all", v$variable)]))
      base <- baselines$baseline_model[baselines$variable == v$variable &
                                         baselines$duration == v$duration]
      board <- if (is.null(cells)) {
        list(schema = dashboard_data_schema, variable = v$id, windows = jarr(windows),
             horizons = jarr(dashboard_horizons(cfg)),
             updated = format_utc(now), models = structure(list(), names = character()))
      } else {
        leaderboard_json(v, cells, windows, base, now, excluded, dashboard_horizons(cfg))
      }
      write_dashboard_json(board, file.path(out_dir, "leaderboard", paste0(v$id, ".json")))
      for (m in names(board$models)) {
        models_by_variable[[m]] <- c(models_by_variable[[m]], v$id)
      }
      scored_models <- union(scored_models, names(board$models))
      write_dashboard_json(targets_json(v, observations, now),
                           file.path(out_dir, "targets", paste0(v$id, ".json")))
      mine <- sites$variable == v$variable & sites$duration == v$duration
      for (site in unique(sites$site_id[mine])) {
        forecasts <- forecast_json(v, site, latest, scored, observations, now)
        file <- paste0(v$id, "__", dashboard_slug(site), ".json")
        write_dashboard_json(forecasts, file.path(out_dir, "forecasts", file))
      }
    }
    if (!is.null(cells)) {
      if (nrow(cells$date) > 0) last_scored <- max(c(last_scored, as.Date(cells$date$date)))
      in_window <- cells$window$window == windows[2]
      active_models <- union(active_models, unique(cells$window$model_id[in_window]))
    }
  }

  for (m in union(registered$model_id, scored_models)) {
    write_dashboard_json(model_json(m, registered, models_by_variable[[m]]),
                         file.path(out_dir, "models", paste0(dashboard_slug(m), ".json")))
  }
  write_dashboard_json(models_index_json(registered, scored_models, models_by_variable),
                       file.path(out_dir, "models.json"))
  activity <- activity_json(submissions %||% empty_events(), registered, last_scored, now)
  write_dashboard_json(activity, file.path(out_dir, "activity.json"))
  stats$n_active_models <- length(active_models)
  publish <- isTRUE(settings$publish_results)
  meta <- dashboard_meta(cfg, variables, baselines, stats, now, publish)
  write_dashboard_json(meta, file.path(out_dir, "meta.json"))
  invisible(out_dir)
}

summary_columns <- c("model_id", "site_id", "variable", "reference_datetime", "datetime",
                     "mean", "quantile02.5", "quantile97.5")

# The dashboard tables with no rows, for a challenge with no data yet.
empty_dashboard_table <- function(part) {
  time <- as.POSIXct(character(), tz = "UTC")
  summaries <- tibble::tibble(model_id = character(), site_id = character(),
                              variable = character(), reference_datetime = time,
                              datetime = time, mean = numeric(),
                              `quantile02.5` = numeric(), `quantile97.5` = numeric())
  switch(part,
    forecasts = summaries,
    analysis = dplyr::mutate(summaries, observation = numeric())
  )
}

# The most recent forecast of each variable made at least `settle_days` days ago
# (so most teams have submitted: a forecast for reference date D is shown by the
# first update on day D + settle_days), at the plot sites. A variable with no
# forecast that old yet (a new challenge) shows its newest one instead of nothing.
latest_forecasts <- function(summaries, sites, now, settle_days = 2) {
  cutoff <- now - lubridate::days(settle_days)
  newest <- function(df) {
    df |>
      dplyr::filter(.data$variable %in% !!unique(sites$variable)) |>
      dplyr::summarise(reference_datetime = max(.data$reference_datetime, na.rm = TRUE),
                       .by = "variable")
  }
  settled <- newest(dplyr::filter(summaries, .data$reference_datetime < !!cutoff))
  refs <- dplyr::union_all(settled, dplyr::anti_join(newest(summaries), settled, by = "variable"))
  summaries |>
    dplyr::filter(.data$site_id %in% !!unique(sites$site_id),
                  .data$datetime > .data$reference_datetime) |>
    dplyr::inner_join(refs, by = c("variable", "reference_datetime")) |>
    dplyr::select(dplyr::all_of(summary_columns)) |>
    dplyr::collect() |>
    dplyr::semi_join(sites, by = c("variable", "site_id"))
}

# For each variable, the latest forecast made at least `lookback` days ago
# that has observations, with them, at the plot sites.
scored_forecasts <- function(scores, sites, now, lookback) {
  newest <- now - lubridate::days(lookback)
  oldest <- now - lubridate::days(2 * lookback)
  refs <- scores |>
    dplyr::filter(.data$reference_datetime <= !!newest, .data$reference_datetime > !!oldest,
                  !is.na(.data$observation),
                  .data$variable %in% !!unique(sites$variable),
                  .data$site_id %in% !!unique(sites$site_id)) |>
    dplyr::summarise(reference_datetime = max(.data$reference_datetime, na.rm = TRUE),
                     .by = "variable")
  scores |>
    dplyr::filter(.data$site_id %in% !!unique(sites$site_id)) |>
    dplyr::inner_join(refs, by = c("variable", "reference_datetime")) |>
    dplyr::select(dplyr::all_of(c(summary_columns, "observation"))) |>
    dplyr::collect() |>
    dplyr::semi_join(sites, by = c("variable", "site_id"))
}

# Headline numbers: forecasts and models submitted, and the targets' span.
dashboard_stats <- function(cfg, conn, now) {
  uri <- bucket_uri(cfg, "summaries_bucket", "bundled-summaries",
                    paste0("project_id=", cfg$project_id))
  summaries <- open_dataset_if_any(uri, conn = conn)
  counts <- if (is.null(summaries)) {
    tibble::tibble(n_forecasts = 0, n_models = 0)
  } else {
    summaries |>
      dplyr::distinct(.data$model_id, .data$variable, .data$duration,
                      .data$reference_datetime) |>
      dplyr::summarise(n_forecasts = dplyr::n(),
                       n_models = dplyr::n_distinct(.data$model_id)) |>
      dplyr::collect()
  }
  files <- targets_files(cfg)
  targets <- readr::read_csv(files, col_select = c("datetime", "variable"),
                             show_col_types = FALSE, progress = FALSE)
  list(
    n_forecasts = as.numeric(counts$n_forecasts),
    n_models = as.numeric(counts$n_models),
    n_variables = dplyr::n_distinct(targets$variable),
    targets_start = format(as.Date(min(targets$datetime, na.rm = TRUE))),
    targets_end = format(as.Date(max(targets$datetime, na.rm = TRUE))),
    updated = format(as.Date(now))
  )
}

# Groups free-text model types: "empirical (a statistical model)" and
# "Empirical (a statistical model)" are the same answer.
model_type_label <- function(x) {
  x <- trimws(sub("\\s*\\(.*\\)$", "", x))
  x <- ifelse(is.na(x) | x == "", "Not described", x)
  paste0(toupper(substring(x, 1, 1)), tolower(substring(x, 2)))
}

# Every site, with a TRUE/FALSE column per target group saying whether the
# group forecasts there.
dashboard_sites <- function(cfg) {
  sites <- read_sites(cfg)
  membership <- purrr::imap(cfg$target_groups, function(settings, group) {
    column <- settings$sites_column %||% tolower(group)
    if (column %in% names(sites)) sites[[column]] %in% c(1, TRUE) else rep(NA, nrow(sites))
  })
  dplyr::bind_cols(sites[c("site_id", "site_name", "latitude", "longitude")],
                   tibble::as_tibble(membership))
}

#' Link to a page of the challenge's catalog in the STAC browser
#'
#' @inheritParams config_get
#' @param path Path of a JSON file in the catalog, e.g.
#'   `"summaries/collection.json"`. The catalog is read from
#'   `catalog_config$catalog_repo` and `catalog_config$catalog_branch`.
#' @return A URL.
#' @export
stac_browser_url <- function(cfg, path = "catalog.json") {
  paste0("https://radiantearth.github.io/stac-browser/#/external/",
         sub("^https://", "", catalog_raw_url(cfg, path)))
}

#' Build the challenge's dashboard
#'
#' Copies the dashboard template shipped with the package to a temporary
#' folder, lays the challenge's own content over it, stages the data
#' ([stage_dashboard_data()]), writes the site settings, and renders the site
#' with Quarto.
#'
#' The challenge's content folder (`dashboard$content_dir`, default
#' `challenge/dashboard`) can hold:
#' * `_content/home.qmd`, `_content/home-more.qmd`: the home page text above
#'   and below the headline numbers;
#' * `_content/instructions-drivers.qmd`, `-automation.qmd`, `-examples.qmd`,
#'   `-submit.qmd`: the challenge-specific sections of the instructions page;
#' * `_content/targets/<group>.md`: each target group's description;
#' * `img/banner.jpg`: the banner at the top of every page;
#' * extra pages (`*.qmd`), listed in the navbar by `dashboard$extra_pages`.
#'
#' A file in the content folder replaces the template's file of the same name;
#' the template's `_content/` files are generic defaults.
#'
#' @inheritParams config_get
#' @param out_dir Folder the rendered site is copied to.
#' @param content_dir The challenge's dashboard content.
#' @param data_dir A folder already staged by [stage_dashboard_data()]. When
#'   given, nothing is read from the buckets and the site is built from it:
#'   for previewing a design, or rebuilding a site from yesterday's data.
#' @return `out_dir`, invisibly.
#' @export
render_dashboard <- function(cfg, out_dir = file.path("dashboard", "docs"),
                             content_dir = dashboard_settings(cfg)$content_dir,
                             data_dir = NULL) {
  quarto <- Sys.which("quarto")
  if (!nzchar(quarto)) cli::cli_abort("Quarto is not installed (no {.code quarto} on the PATH).")
  template <- system.file("dashboard", package = "challengeci", mustWork = TRUE)
  build <- tempfile("dashboard")
  dir.create(build)
  on.exit(unlink(build, recursive = TRUE), add = TRUE)

  copy_dir(template, build)
  if (dir.exists(content_dir)) {
    copy_dir(content_dir, build)
  } else {
    cli::cli_warn("No dashboard content in {.path {content_dir}}; using the template's defaults.")
  }
  if (is.null(data_dir)) {
    stage_dashboard_data(cfg, out_dir = file.path(build, "data"))
  } else {
    dir.create(file.path(build, "data"))
    copy_dir(data_dir, file.path(build, "data"))
  }
  write_quarto_metadata(cfg, file.path(build, "_challenge.yml"))
  write_dashboard_shell(cfg, build, banner = file.exists(file.path(build, "img", "banner.jpg")))

  env <- c(CHALLENGE_CONFIG = config_file(cfg))
  # The pages run in another R process, whose default dry-run folder differs.
  if (is_dry_run()) env <- c(env, DRY_RUN_DIR = normalizePath(dry_run_dir(), mustWork = FALSE))
  source_dir <- package_source_dir()
  if (!is.null(source_dir)) env <- c(env, CHALLENGECI_SOURCE = source_dir)
  log_step("Rendering the dashboard")
  # Rendered from inside the build folder: Quarto mis-resolves some absolute
  # temporary paths (macOS's /var symlink).
  status <- withr::with_envvar(env, withr::with_dir(build, system2(quarto, "render")))
  if (!identical(status, 0L)) cli::cli_abort("Quarto failed to render the dashboard.")

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  copy_dir(file.path(build, "docs"), out_dir)
  log_step("Dashboard written to {.path {out_dir}}")
  invisible(out_dir)
}

# Copy the contents of `from` into `to`, replacing files of the same name.
copy_dir <- function(from, to) {
  items <- list.files(from, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  ok <- file.copy(items, to, recursive = TRUE, overwrite = TRUE)
  if (!all(ok)) cli::cli_abort("Could not copy {.path {items[!ok]}} to {.path {to}}.")
  invisible(to)
}

# The config file `cfg` was read from (an absolute path), or a temporary copy.
config_file <- function(cfg) {
  path <- attr(cfg, "path")
  if (!is.null(path) && file.exists(path)) return(normalizePath(path))
  path <- tempfile(fileext = ".yaml")
  yaml::write_yaml(unclass(cfg), path)
  path
}

# The package's source folder when it is loaded from a development copy
# (pkgload), so the dashboard pages load the same code; NULL when installed.
package_source_dir <- function() {
  # Under pkgload, system.file() points at the source's inst/ folder.
  dir <- system.file(package = "challengeci")
  for (candidate in c(dir, dirname(dir))) {
    if (file.exists(file.path(candidate, "R", "stages.R"))) return(normalizePath(candidate))
  }
  NULL
}

# The pages every dashboard has, in navigation order. The Quarto pages behind
# them are in inst/dashboard/.
dashboard_pages <- list(
  list(href = "index.html", title = "Overview"),
  list(href = "targets.html", title = "Targets"),
  list(href = "leaderboard.html", title = "Leaderboard"),
  list(href = "forecasts.html", title = "Forecasts"),
  list(href = "data.html", title = "Data"),
  list(href = "participate.html", title = "Participate")
)

# The title in a .qmd file's front matter, or NULL.
page_title <- function(path) {
  if (!file.exists(path)) return(NULL)
  lines <- utils::head(readLines(path, warn = FALSE), 30)
  title <- sub("^title:\\s*[\"']?(.*?)[\"']?\\s*$", "\\1", grep("^title:", lines, value = TRUE)[1])
  if (is.na(title) || !nzchar(title)) NULL else title
}

# The navigation: the standard pages, then the challenge's own
# (`dashboard$extra_pages`, whose `href` may name the .qmd source). A page's
# title is the configured one, else the `title:` of its .qmd in `dir` (the
# build folder), else its file name.
dashboard_nav <- function(cfg, dir = NULL) {
  extra <- purrr::map(dashboard_settings(cfg)$extra_pages, function(p) {
    href <- sub("\\.qmd$", ".html", p$href)
    named <- tools::toTitleCase(gsub("[-_]", " ", sub("\\.html$", "", basename(href))))
    from_file <- if (!is.null(dir)) page_title(file.path(dir, sub("\\.html$", ".qmd", href)))
    list(href = href, title = p$title %||% from_file %||% named)
  })
  c(dashboard_pages, extra)
}

html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# An HTML template of the dashboard (inst/dashboard/_*.template).
read_template <- function(name) {
  path <- system.file("dashboard", name, package = "challengeci", mustWork = TRUE)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Fills `{{name}}` slots in an HTML template.
fill_template <- function(template, ...) {
  values <- list(...)
  for (name in names(values)) {
    template <- gsub(paste0("{{", name, "}}"), values[[name]], template, fixed = TRUE)
  }
  template
}

# The header and footer every page includes (_header.html, _footer.html in the
# build folder). The navigation marks the current page in the browser
# (js/shell.js). A challenge banner image becomes a strip under the header.
write_dashboard_shell <- function(cfg, dir, banner = FALSE) {
  settings <- dashboard_settings(cfg)
  nav <- purrr::map_chr(dashboard_nav(cfg, dir), function(p) {
    sprintf('<a href="%s">%s</a>', html_escape(p$href), html_escape(p$title))
  })
  strip <- paste0('<div class="hub-banner" role="img" aria-label="" ',
                  'style="height:140px;background:url(img/banner.jpg) center/cover"></div>\n')
  title <- html_escape(settings$title %||% cfg$challenge_long_name %||% cfg$project_id)
  header <- fill_template(read_template("_header.template"), title = title,
                          nav = paste(nav, collapse = "\n"), banner = if (banner) strip else "")
  repo <- config_get(cfg, "github_repo", default = NULL)
  contact <- if (is.null(settings$contact_email)) "" else
    paste0(" &middot; Contact: ", html_escape(settings$contact_email))
  source <- if (is.null(repo)) "" else
    paste0('<a href="https://github.com/', html_escape(repo), '">Source on GitHub</a> &middot; ')
  footer <- fill_template(read_template("_footer.template"), contact = contact, source = source)
  writeLines(header, file.path(dir, "_header.html"), useBytes = TRUE)
  writeLines(footer, file.path(dir, "_footer.html"), useBytes = TRUE)
  invisible(dir)
}

# Site-wide Quarto settings that come from the config. _quarto.yml lists this
# file under metadata-files, so Quarto merges it into the project settings. A
# challenge's own styles (challenge.css next to the file) load after ours.
write_quarto_metadata <- function(cfg, path) {
  repo <- paste0("https://github.com/", config_get(cfg, "github_repo"))
  settings <- dashboard_settings(cfg)
  meta <- list(website = list(
    title = settings$title %||% cfg$challenge_long_name,
    `site-url` = cfg$challenge_url,
    `repo-url` = repo
  ))
  own <- file.exists(file.path(dirname(path), "challenge.css"))
  css <- c("styles.css", if (own) "challenge.css")
  meta$format <- list(html = list(css = css))
  yaml::write_yaml(meta, path)
}
