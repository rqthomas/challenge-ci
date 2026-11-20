# The data the dashboard pages read: small public JSON files written by
# stage_dashboard_data() (R/dashboard.R). This file builds them. The format is
# the dashboard's data contract, described in docs/dashboard-data.md; the pages
# (inst/dashboard/js/) read only these files, never a bucket, so a private
# challenge never puts a key in the browser.

# Version of the contract; the pages refuse data with a different one.
dashboard_data_schema <- 1L

# A name safe to use in a file name or URL.
dashboard_slug <- function(x) gsub("[^A-Za-z0-9_.-]", "_", x)

# The id of a variable on the dashboard: its name and duration, so two
# durations of one variable stay apart.
dashboard_variable_id <- function(variable, duration) {
  dashboard_slug(paste0(variable, "_", duration))
}

#' Windows of the leaderboard, in days
#'
#' Daily and shorter variables are compared over the last 7, 30 and 90 days;
#' weekly and longer ones over the last 90, 180 and 365, since they are
#' observed slowly. The middle window is the one the leaderboard opens on and
#' the one the horizon curves use.
#'
#' @param duration ISO 8601 duration, e.g. `"P1D"`.
#' @return Three numbers of days.
#' @export
#' @examples
#' dashboard_windows("P1D")
#' dashboard_windows("P1W")
dashboard_windows <- function(duration) {
  if (dashboard_lookback_days(duration) >= 365) c(90, 180, 365) else c(7, 30, 90)
}

#' The baseline each variable's skill is measured against
#'
#' Skill compares a model with a baseline on the same sites and days: one
#' minus the ratio of their summed CRPS. The baseline is the group's
#' `climatology` baseline for a variable shorter than a week and its
#' `weekly_climatology` for a longer one, unless `dashboard$skill_baseline`
#' names a model id to use for every variable. A variable with no such
#' baseline has no skill, and its leaderboard ranks by CRPS.
#'
#' @inheritParams config_get
#' @return A tibble with `variable`, `duration` and `baseline_model`
#'   (`NA` when there is none).
#' @export
skill_baselines <- function(cfg) {
  override <- dashboard_settings(cfg)$skill_baseline
  vars <- target_variables(cfg)
  baseline_for <- function(group, variable, duration) {
    if (!is.null(override)) return(as.character(override))
    long <- dashboard_lookback_days(duration) >= 365
    wanted <- if (long) "weekly_climatology" else "climatology"
    for (b in cfg$target_groups[[group]]$baselines) {
      listed <- b$args$variables
      if (identical(b$method, wanted) && (is.null(listed) || variable %in% listed)) {
        return(as.character(b$model_id))
      }
    }
    NA_character_
  }
  vars$baseline_model <- purrr::pmap_chr(vars[c("group", "variable", "duration")],
                                         baseline_for)
  vars[c("variable", "duration", "baseline_model")]
}

# One day's rows of CRPS for every model, with the baseline's CRPS on the same
# forecast (site, reference time and valid time) where there is one. `scores`
# is a lazy duckdb table of scores; `baselines` is the tibble from
# skill_baselines(). Only the rows used by the leaderboards are kept, as a
# table in the connection, so the aggregations below scan the bucket once.
leaderboard_rows <- function(scores, baselines, now, windows, max_horizon,
                             conn = duckdbfs::cached_connection()) {
  since <- now - lubridate::days(max(windows))
  variables <- unique(baselines$variable)
  with_baseline <- dplyr::filter(baselines, !is.na(.data$baseline_model))
  rows <- scores |>
    dplyr::filter(.data$reference_datetime >= !!since, !is.na(.data$crps),
                  .data$variable %in% !!variables) |>
    dplyr::mutate(horizon = date_diff("day", as.POSIXct(reference_datetime),
                                      as.POSIXct(datetime)),
                  date = as.Date(as.POSIXct(reference_datetime))) |>
    dplyr::filter(.data$horizon > 0, .data$horizon <= !!max_horizon) |>
    dplyr::select("variable", "model_id", "site_id", "reference_datetime", "datetime",
                  "horizon", "date", "crps")
  if (nrow(with_baseline) == 0) {
    return(rows |> dplyr::mutate(crps_base = NA_real_, matched = FALSE) |> dplyr::compute())
  }
  # The baseline model can differ by variable, so it is a small table joined in.
  map_name <- paste0("baseline_map_", as.integer(stats::runif(1, 1, 1e9)))
  dplyr::copy_to(conn, with_baseline[c("variable", "baseline_model")], map_name,
                 overwrite = TRUE, temporary = TRUE)
  base <- dplyr::tbl(conn, map_name) |>
    dplyr::inner_join(rows, by = "variable") |>
    dplyr::filter(.data$model_id == .data$baseline_model) |>
    dplyr::select("variable", "site_id", "reference_datetime", "datetime",
                  crps_base = "crps")
  rows |>
    dplyr::left_join(base, by = c("variable", "site_id", "reference_datetime", "datetime")) |>
    dplyr::mutate(matched = !is.na(.data$crps_base)) |>
    dplyr::compute()
}

# Sums that make a skill: all rows and rows that have a baseline. Means and
# ratios are taken afterwards, from sums, so groups combine without bias.
sum_scores <- function(rows, ...) {
  rows |>
    dplyr::summarise(
      n = dplyr::n(),
      nd = dplyr::n_distinct(.data$date),
      crps_sum = sum(.data$crps, na.rm = TRUE),
      n_matched = sum(dplyr::if_else(.data$matched, 1, 0), na.rm = TRUE),
      crps_matched = sum(dplyr::if_else(.data$matched, .data$crps, 0), na.rm = TRUE),
      base_matched = sum(dplyr::if_else(.data$matched, .data$crps_base, 0), na.rm = TRUE),
      .by = c("variable", "model_id", ...)
    ) |>
    dplyr::collect() |>
    dplyr::mutate(dplyr::across(c("n", "nd", "n_matched"), as.numeric))
}

# The aggregations the leaderboard pages show, from leaderboard_rows(): by
# window, by horizon (within the middle window) and by reference date.
leaderboard_cells <- function(rows, now, windows) {
  by_window <- purrr::map(windows, function(w) {
    since <- as.Date(now) - w
    rows |>
      dplyr::filter(.data$date >= !!since) |>
      sum_scores() |>
      dplyr::mutate(window = w)
  }) |>
    purrr::list_rbind()
  middle <- as.Date(now) - windows[2]
  list(
    window = by_window,
    horizon = rows |>
      dplyr::filter(.data$date >= !!middle) |>
      sum_scores("horizon") |>
      dplyr::mutate(horizon = as.numeric(.data$horizon)),
    date = sum_scores(rows, "date") |> dplyr::mutate(date = as.Date(.data$date))
  )
}

# Skill (one minus the ratio of summed CRPS on forecasts both models made) and
# mean CRPS from the sums of sum_scores(). NA where there is no baseline.
cell_skill <- function(cells) {
  dplyr::mutate(
    cells,
    skill = dplyr::if_else(.data$n_matched > 0 & .data$base_matched > 0,
                           1 - .data$crps_matched / .data$base_matched, NA_real_),
    crps = .data$crps_sum / .data$n
  )
}

# JSON-ready numbers: rounded, with NA written as null. `jarr()` keeps an
# array an array when it has one element (jsonlite would unbox it).
jnum <- function(x, digits = 4) signif(as.numeric(x), digits)
jarr <- function(x, digits = NULL) {
  as.list(if (is.null(digits)) x else jnum(x, digits))
}

# The leaderboard file of one variable (see docs/dashboard-data.md).
leaderboard_json <- function(variable_row, cells, windows, baseline, now, excluded = character()) {
  keep <- function(df) {
    dplyr::filter(df, .data$variable == variable_row$variable,
                  !.data$model_id %in% excluded) |> cell_skill()
  }
  w <- keep(cells$window)
  h <- keep(cells$horizon)
  t <- keep(cells$date)
  models <- sort(unique(w$model_id))
  per_model <- purrr::map(rlang::set_names(models), function(m) {
    mw <- w[w$model_id == m, ]
    mh <- h[h$model_id == m, ] |> dplyr::arrange(.data$horizon)
    mt <- t[t$model_id == m, ] |> dplyr::arrange(.data$date)
    list(
      w = purrr::map(rlang::set_names(as.character(windows)), function(d) {
        r <- mw[mw$window == as.numeric(d), ]
        if (nrow(r) == 0) return(NULL)
        list(skill = jnum(r$skill), crps = jnum(r$crps), n = r$n, dates = r$nd)
      }) |> purrr::compact(),
      h = list(h = jarr(mh$horizon), skill = jarr(mh$skill, 4), crps = jarr(mh$crps, 4)),
      t = list(d = jarr(format(mt$date)), skill = jarr(mt$skill, 4), crps = jarr(mt$crps, 4))
    )
  })
  list(schema = dashboard_data_schema, variable = variable_row$id,
       baseline = if (is.na(baseline)) NULL else baseline,
       windows = jarr(windows), updated = format_utc(now), models = per_model)
}

format_utc <- function(x) format(as.POSIXct(x, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# Observations at the plot sites, for the forecast charts: the last `days` days.
plot_observations <- function(cfg, sites, now, days = 120) {
  files <- targets_files(cfg)
  readr::read_csv(files, col_select = dplyr::any_of(c("site_id", "datetime", "variable",
                                                      "duration", "observation")),
                  show_col_types = FALSE, progress = FALSE) |>
    dplyr::filter(!is.na(.data$observation),
                  as.Date(.data$datetime) >= as.Date(now) - days) |>
    dplyr::semi_join(sites, by = c("variable", "site_id"))
}

# Keeps at most `n` evenly spaced elements of an index 1..len.
thin_index <- function(len, n = 400) {
  if (len <= n) return(seq_len(len))
  unique(round(seq(1, len, length.out = n)))
}

# One forecast of the forecast explorer: per model, the points of its mean and
# interval as offsets from the reference time (days).
forecast_set <- function(df, id) {
  if (nrow(df) == 0) return(NULL)
  reference <- max(df$reference_datetime)
  df <- dplyr::filter(df, .data$reference_datetime == reference) |>
    dplyr::arrange(.data$model_id, .data$datetime)
  models <- purrr::map(split(df, df$model_id), function(m) {
    i <- thin_index(nrow(m))
    m <- m[i, ]
    list(d = jarr(as.numeric(difftime(m$datetime, reference, units = "days")), 5),
         m = jarr(m$mean, 4), l = jarr(m$`quantile02.5`, 4), u = jarr(m$`quantile97.5`, 4))
  })
  list(id = id, reference = format_utc(reference), models = models)
}

# The forecast file of one variable and site (see docs/dashboard-data.md).
forecast_json <- function(variable_row, site_id, latest, scored, observations, now) {
  variable <- variable_row$variable
  rows <- function(df) dplyr::filter(df, .data$variable == !!variable, .data$site_id == !!site_id)
  obs <- rows(observations) |> dplyr::arrange(.data$datetime)
  if ("duration" %in% names(obs)) obs <- dplyr::filter(obs, .data$duration == variable_row$duration)
  sets <- purrr::compact(list(forecast_set(rows(latest), "latest"),
                              forecast_set(rows(scored), "scored")))
  list(schema = dashboard_data_schema, variable = variable_row$id, site_id = site_id,
       obs = list(t = jarr(format_utc(obs$datetime)), v = jarr(obs$observation, 5)),
       sets = sets, updated = format_utc(now))
}

# The registration answers worth showing on a model's page.
model_answer_columns <- c("dynamic", "ic_uncertainty", "has_parameters", "parameter_uncertainty",
                          "assimilation", "uses_drivers", "driver_uncertainty",
                          "process_uncertainty", "obs_uncertainty", "structural_uncertainty")

# The file of one model (see docs/dashboard-data.md): its registration, and the
# variables it has scores for.
model_json <- function(model_id, registered, variable_ids) {
  row <- registered[registered$model_id == model_id, ]
  row <- if (nrow(row) > 0) row[1, ] else NULL
  value <- function(col) {
    if (is.null(row) || !col %in% names(row)) return(NULL)
    v <- row[[col]]
    if (is.na(v) || !nzchar(v)) NULL else as.character(v)
  }
  answers <- purrr::map(rlang::set_names(model_answer_columns), value) |> purrr::compact()
  public <- identical(tolower(value("public_contact") %||% ""), "yes")
  purrr::compact(list(
    schema = dashboard_data_schema,
    model_id = model_id,
    registered = !is.null(row),
    baseline = isTRUE(row$baseline),
    long_name = value("long_name") %||% model_id,
    description = value("description"),
    model_type = if (!is.null(row)) model_type_label(row$model_type) else "Not described",
    code_url = value("code_url"),
    contact_name = if (public) value("contact_name"),
    answers = if (length(answers) > 0) answers,
    variables = as.list(variable_ids)
  ))
}

# The index of models: what the leaderboards need to label and filter them.
models_index_json <- function(registered, scored_models, variable_ids_by_model) {
  ids <- sort(union(registered$model_id, scored_models))
  list(schema = dashboard_data_schema, models = purrr::map(ids, function(id) {
    row <- registered[registered$model_id == id, ]
    list(model_id = id,
         long_name = if (nrow(row) > 0 && !is.na(row$long_name[1])) row$long_name[1] else id,
         model_type = if (nrow(row) > 0) model_type_label(row$model_type[1]) else "Not described",
         baseline = nrow(row) > 0 && isTRUE(row$baseline[1]),
         variables = as.list(variable_ids_by_model[[id]] %||% character()))
  }))
}

# What the dashboard says about each dataset's columns.
dataset_columns <- list(
  targets = list(
    c("project_id", "text", "The challenge id"),
    c("site_id", "text", "Site code (see Sites)"),
    c("datetime", "datetime", "The time observed, UTC"),
    c("duration", "text", "Time step as an ISO 8601 duration, e.g. P1D for a day"),
    c("variable", "text", "The variable observed"),
    c("observation", "number", "The observed value")
  ),
  forecasts = list(
    c("project_id", "text", "The challenge id"),
    c("model_id", "text", "The model that made the forecast"),
    c("reference_datetime", "datetime", "When the forecast starts"),
    c("datetime", "datetime", "The time being forecast"),
    c("duration", "text", "Time step of the forecast"),
    c("site_id", "text", "Site code"),
    c("variable", "text", "The variable forecast"),
    c("family", "text", "ensemble, sample, or a distribution such as normal"),
    c("parameter", "text", "Ensemble member number, or the distribution's parameter (mu, sigma)"),
    c("prediction", "number", "The forecast value"),
    c("pub_datetime", "datetime", "When the file was processed")
  ),
  summaries = list(
    c("model_id", "text", "The model that made the forecast"),
    c("reference_datetime", "datetime", "When the forecast starts"),
    c("datetime", "datetime", "The time being forecast"),
    c("site_id", "text", "Site code"),
    c("variable", "text", "The variable forecast"),
    c("mean", "number", "Mean of the forecast distribution"),
    c("median", "number", "Median"),
    c("sd", "number", "Standard deviation"),
    c("quantile02.5", "number", "Lower end of the 95% interval"),
    c("quantile97.5", "number", "Upper end of the 95% interval")
  ),
  scores = list(
    c("model_id", "text", "The model that made the forecast"),
    c("reference_datetime", "datetime", "When the forecast starts"),
    c("datetime", "datetime", "The time scored"),
    c("site_id", "text", "Site code"),
    c("variable", "text", "The variable forecast"),
    c("observation", "number", "The observed value"),
    c("crps", "number", "Continuous ranked probability score; lower is better"),
    c("logs", "number", "Logarithmic score; lower is better")
  ),
  results = list(
    c("file", "text", "The file's path in the model's repository"),
    c("model_id", "text", "The model named in the file"),
    c("status", "text", "processed, invalid, skipped, unreadable or failed"),
    c("reason", "text", "Why a file was refused, when it was"),
    c("first_seen", "datetime", "When the challenge first saw this outcome")
  )
)

# The datasets the Data page describes, with where each can be read.
dashboard_datasets <- function(cfg, variables, publish_results = TRUE) {
  project <- paste0("project_id=", cfg$project_id)
  url <- function(key, ...) {
    tryCatch(bucket_uri(cfg, key, ..., scheme = "https"), error = function(e) NA_character_)
  }
  columns <- function(name) {
    purrr::map(dataset_columns[[name]], \(c) list(name = c[1], type = c[2], text = c[3]))
  }
  dataset <- function(id, name, about, format, urls, public = FALSE) {
    list(id = id, name = name, about = about, format = format, urls = as.list(urls),
         public = public, columns = columns(id))
  }
  datasets <- list(
    dataset("targets", "Targets",
            "The observations to forecast. Forecasts are scored against them.",
            "CSV, gzip", unique(stats::na.omit(variables$targets_file))),
    dataset("forecasts", "Forecasts",
            paste("Every forecast that passed validation, from every model and baseline,",
                  "partitioned by duration, model and date."),
            "Parquet, partitioned", url("forecasts_bucket", "bundled-parquet", project)),
    dataset("summaries", "Forecast summaries",
            "The mean, median, standard deviation and 95% interval of every forecast.",
            "Parquet, partitioned", url("summaries_bucket", "bundled-summaries", project)),
    dataset("scores", "Scores",
            paste("One score per model, site, forecast time and lead time, computed once the",
                  "observation is available. The leaderboards are built from them."),
            "Parquet, partitioned", url("scores_bucket", "bundled-parquet", project))
  )
  if (publish_results) {
    results <- dataset("results", "Submission results",
                       paste("What the challenge did with each file it read: processed, or",
                             "invalid with the reason. \"Check my submissions\" reads this."),
                       "JSON, one file per model", "data/results/<model_id>.json", public = TRUE)
    datasets <- c(datasets, list(results))
  }
  # The data are open to read when the bucket is public (the results list is
  # published on the site either way).
  purrr::map(datasets, function(d) {
    if (!isTRUE(d$public)) d$public <- !isFALSE(cfg$public_read)
    d
  })
}

# Everything the pages need to know about the challenge (see
# docs/dashboard-data.md): names, links, variables, sites, groups, datasets,
# access and headline numbers.
dashboard_meta <- function(cfg, variables, baselines, stats, now, publish_results = TRUE) {
  settings <- dashboard_settings(cfg)
  github_on <- !is.null(cfg$submissions$github$registry)
  sites <- dashboard_sites(cfg)
  group_names <- names(cfg$target_groups)
  vars <- dplyr::left_join(variables, baselines, by = c("variable", "duration"))
  list(
    schema = dashboard_data_schema,
    updated = format_utc(now),
    challenge = purrr::compact(list(
      id = cfg$project_id,
      name = settings$title %||% cfg$challenge_long_name,
      url = cfg$challenge_url,
      repo = cfg$github_repo,
      tagline = settings$tagline,
      contact_email = settings$contact_email,
      registration_form_url = settings$registration_form_url,
      example_submission_repo = settings$example_submission_repo,
      key_request_url = settings$key_request_url,
      github_submissions = github_on,
      issue_registration = isTRUE(cfg$submissions$github$issue_registration),
      catalog_url = stac_browser_url(cfg),
      citation = cfg$catalog_config$citation_text
    )),
    access = purrr::compact(list(
      public_read = !isFALSE(cfg$public_read),
      endpoint = cfg$endpoint,
      results_published = publish_results
    )),
    stats = stats,
    variables = purrr::map(seq_len(nrow(vars)), function(i) {
      v <- vars[i, ]
      purrr::compact(list(
        id = v$id, variable = v$variable, duration = v$duration, group = v$group,
        long_name = v$long_name, description = v$description, label = v$label,
        max_horizon = v$max_horizon,
        baseline = if (is.na(v$baseline_model)) NULL else v$baseline_model,
        windows = as.list(dashboard_windows(v$duration))
      ))
    }),
    sites = purrr::map(seq_len(nrow(sites)), function(i) {
      s <- sites[i, ]
      member <- group_names[vapply(group_names, function(g) isTRUE(s[[g]]), logical(1))]
      list(site_id = s$site_id, site_name = s$site_name, latitude = s$latitude,
           longitude = s$longitude, groups = as.list(member))
    }),
    groups = purrr::imap(cfg$target_groups, function(g, name) {
      focal <- as.character(unlist(g$focal_sites))
      list(name = name, theme = g$theme, focal_sites = as.list(focal),
           plot_sites = as.list(utils::head(focal, settings$n_plot_sites)))
    }) |> unname(),
    datasets = dashboard_datasets(cfg, variables, publish_results),
    leaderboard_max_horizon = settings$leaderboard_max_horizon,
    min_forecasts = settings$min_forecasts
  )
}

# Published outcomes of every file, per model (see write_submission_results()).
# Returns the names of the files written. `rows` keeps the most recent per
# model; the index maps repositories to the models they submit.
stage_results <- function(cfg, out_dir, keep = 50) {
  dir.create(file.path(out_dir, "results"), recursive = TRUE, showWarnings = FALSE)
  folder <- bucket_uri(cfg, "forecasts_bucket", "submission_results", scheme = "remote")
  # The results are optional: a challenge that has published none has no folder,
  # and a failure must not stop the dashboard, but it must not pass unnoticed.
  files <- tryCatch(remote_files(folder), error = function(e) {
    cli::cli_warn("Could not list the published submission results: {conditionMessage(e)}")
    character()
  })
  files <- files[grepl("\\.csv$", files)]
  index <- list()
  for (f in files) {
    name <- sub("\\.csv$", "", basename(f))
    rows <- tryCatch(read_published_results(paste0(folder, "/", basename(f))), error = function(e) {
      cli::cli_warn("Could not read the results in {.file {basename(f)}}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(rows) || nrow(rows) == 0) next
    rows <- rows |>
      dplyr::arrange(dplyr::desc(.data$first_seen)) |>
      utils::head(keep)
    fields <- intersect(c("file", "status", "reason", "warnings", "first_seen", "source"),
                        names(rows))
    out <- purrr::pmap(rows[fields], function(...) {
      purrr::map(list(...), \(v) if (is.na(v)) NULL else v) |> purrr::compact()
    })
    jsonlite::write_json(list(schema = dashboard_data_schema, name = name, rows = out),
                         file.path(out_dir, "results", paste0(dashboard_slug(name), ".json")),
                         auto_unbox = TRUE)
    index[[name]] <- list(sources = as.list(unique(stats::na.omit(rows$source))),
                          last = rows$first_seen[1],
                          models = as.list(unique(stats::na.omit(rows$model_id))))
  }
  jsonlite::write_json(list(schema = dashboard_data_schema, results = index),
                       file.path(out_dir, "results", "index.json"), auto_unbox = TRUE)
  invisible(names(index))
}

write_dashboard_json <- function(x, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(x, path, auto_unbox = TRUE, null = "null", na = "null",
                       digits = NA)
}
