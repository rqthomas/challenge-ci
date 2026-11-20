# The dashboard's data contract (docs/dashboard-data.md): what the staging
# code writes for the pages in inst/dashboard/js/.

test_that("windows are 7, 30 and 90 days, or longer for slow variables", {
  expect_equal(dashboard_windows("P1D"), c(7, 30, 90))
  expect_equal(dashboard_windows("PT30M"), c(7, 30, 90))
  expect_equal(dashboard_windows("P1W"), c(90, 180, 365))
})

test_that("skill is measured against the group's climatology baseline", {
  cfg <- dashboard_test_config()
  b <- skill_baselines(cfg)
  expect_equal(b$baseline_model[b$variable == "temperature"], "climatology")
  expect_equal(b$baseline_model[b$variable == "oxygen"], "climatology")
  # A group with no baseline has no skill.
  expect_true(is.na(b$baseline_model[b$variable == "richness"]))

  cfg$dashboard$skill_baseline <- "mean"
  expect_equal(unique(skill_baselines(cfg)$baseline_model), "mean")

  # A weekly variable uses the weekly climatology, and `args$variables` limits
  # a baseline to the variables it forecasts.
  cfg <- dashboard_test_config()
  cfg$target_groups$Birds$baselines <- list(
    list(model_id = "weekly", method = "weekly_climatology"))
  cfg$target_groups$Lakes$baselines[[1]]$args <- list(variables = "temperature")
  b <- skill_baselines(cfg)
  expect_equal(b$baseline_model[b$variable == "richness"], "weekly")
  expect_true(is.na(b$baseline_model[b$variable == "oxygen"]))
})

# Scores of three models on two sites and three horizons over ten days. The
# baseline scores 2, model `a` 1 and model `c` 4. Model `a` also has a forecast
# the baseline did not make.
fake_scores <- function(now) {
  grid <- tidyr::expand_grid(
    model_id = c("climatology", "a", "c"), site_id = c("AAAA", "BBBB"),
    day = 1:10, horizon = 1:3
  ) |>
    dplyr::mutate(
      reference_datetime = as.POSIXct(as.Date(now) - day, tz = "UTC"),
      datetime = reference_datetime + horizon * 86400,
      variable = "temperature",
      crps = c(climatology = 2, a = 1, c = 4)[model_id]
    ) |>
    dplyr::select(-day, -horizon)
  extra <- tibble::tibble(
    model_id = "a", site_id = "CCCC", variable = "temperature",
    reference_datetime = as.POSIXct(as.Date(now) - 1, tz = "UTC"),
    datetime = reference_datetime + 86400, crps = 100)
  dplyr::bind_rows(grid, extra)
}

test_that("leaderboard cells give skill on forecasts both models made", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-30")
  baselines <- tibble::tibble(variable = "temperature", duration = "P1D",
                              baseline_model = "climatology")
  rows <- leaderboard_rows(lazy_table(fake_scores(now)), baselines, now, c(7, 30, 90), 35)
  cells <- leaderboard_cells(rows, now, c(7, 30, 90))

  w <- cell_skill(cells$window)
  a30 <- w[w$model_id == "a" & w$window == 30, ]
  expect_equal(a30$skill, 0.5)
  # The unmatched forecast counts towards the mean CRPS but not the skill.
  expect_equal(a30$n, 60 + 1)
  expect_equal(a30$crps, (60 * 1 + 100) / 61)
  expect_equal(w$skill[w$model_id == "c" & w$window == 30], -1)
  expect_equal(w$skill[w$model_id == "climatology" & w$window == 30], 0)
  # Forecasts made in the last 7 days only.
  expect_equal(w$nd[w$model_id == "c" & w$window == 7], 7)
  expect_equal(w$nd[w$model_id == "c" & w$window == 90], 10)

  h <- cell_skill(cells$horizon)
  expect_setequal(h$horizon, 1:3)
  expect_equal(unique(h$skill[h$model_id == "a"]), 0.5, ignore_attr = TRUE)
  d <- cells$date
  expect_equal(nrow(d[d$model_id == "a", ]), 10)
})

test_that("a variable without a baseline gets CRPS but no skill", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-30")
  scores <- fake_scores(now) |> dplyr::filter(model_id != "climatology")
  baselines <- tibble::tibble(variable = "temperature", duration = "P1D",
                              baseline_model = NA_character_)
  rows <- leaderboard_rows(lazy_table(scores), baselines, now, c(7, 30, 90), 35)
  w <- cell_skill(leaderboard_cells(rows, now, c(7, 30, 90))$window)
  expect_true(all(is.na(w$skill)))
  expect_equal(w$crps[w$model_id == "c" & w$window == 30], 4)
})

test_that("the leaderboard file lists each model's windows, horizons and dates", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-30")
  baselines <- tibble::tibble(variable = "temperature", duration = "P1D",
                              baseline_model = "climatology")
  rows <- leaderboard_rows(lazy_table(fake_scores(now)), baselines, now, c(7, 30, 90), 35)
  cells <- leaderboard_cells(rows, now, c(7, 30, 90))
  v <- list(id = "temperature_P1D", variable = "temperature")
  board <- leaderboard_json(v, cells, c(7, 30, 90), "climatology", now, excluded = "c")
  expect_equal(board$schema, dashboard_data_schema)
  expect_equal(board$baseline, "climatology")
  expect_setequal(names(board$models), c("a", "climatology"))
  a <- board$models$a
  expect_equal(a$w[["30"]]$skill, 0.5)
  expect_equal(unlist(a$h$h), 1:3)
  expect_length(a$t$d, 10)
  # Round trip: arrays stay arrays, NA is null.
  json <- jsonlite::toJSON(board, auto_unbox = TRUE, null = "null", na = "null", digits = NA)
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  expect_equal(parsed$models$a$w[["30"]]$skill, 0.5)
  expect_true(is.list(parsed$models$a$h$h))
})

test_that("a single-element array stays an array in the JSON", {
  json <- jsonlite::toJSON(list(h = jarr(1), x = 5), auto_unbox = TRUE)
  expect_equal(as.character(json), '{"h":[1],"x":5}')
  expect_equal(as.character(jsonlite::toJSON(list(v = jarr(c(1, NA), 3)), auto_unbox = TRUE,
                                             na = "null")), '{"v":[1,null]}')
})

test_that("forecast files hold the latest and scored forecasts with observations", {
  ref <- utc("2024-06-01")
  summaries <- tidyr::expand_grid(model_id = c("m1", "m2"), site_id = "AAAA",
                                  variable = "temperature", lead = 1:3) |>
    dplyr::mutate(reference_datetime = ref, datetime = ref + lead * 86400,
                  mean = lead + 0.123456, `quantile02.5` = lead - 1, `quantile97.5` = lead + 1) |>
    dplyr::select(-lead)
  obs <- tibble::tibble(site_id = "AAAA", variable = "temperature", duration = "P1D",
                        datetime = utc("2024-05-30") + 86400 * 0:3, observation = c(5, 6, 7, 8))
  v <- list(id = "temperature_P1D", variable = "temperature", duration = "P1D")
  out <- forecast_json(v, "AAAA", summaries, summaries[0, ], obs, utc("2024-06-10"))
  expect_equal(out$variable, "temperature_P1D")
  expect_length(out$sets, 1)
  expect_equal(out$sets[[1]]$id, "latest")
  expect_equal(unlist(out$sets[[1]]$models$m1$d), 1:3)
  expect_equal(unlist(out$sets[[1]]$models$m1$m)[1], 1.123)
  expect_length(out$obs$v, 4)
  # No data: no sets, still a valid file.
  none <- forecast_json(v, "ZZZZ", summaries, summaries[0, ], obs, utc("2024-06-10"))
  expect_length(none$sets, 0)
})

test_that("long forecasts are thinned to a few hundred points", {
  expect_equal(thin_index(10), 1:10)
  idx <- thin_index(5000)
  expect_lte(length(idx), 400)
  expect_equal(idx[c(1, length(idx))], c(1, 5000))
})

test_that("model files carry the registration and keep contacts private", {
  registered <- tibble::tibble(
    model_id = c("m1", "base"), long_name = c("Model one", "Baseline"),
    description = c("Does things", NA), model_type = c("Empirical (stats)", "Empirical"),
    code_url = c("https://example.org/m1", NA), contact_name = c("Ada", "Org"),
    public_contact = c("No", "Yes"), uses_drivers = c("Yes", "No"),
    baseline = c(FALSE, TRUE))
  m <- model_json("m1", registered, c("temperature_P1D"))
  expect_equal(m$model_type, "Empirical")
  expect_null(m$contact_name)
  expect_equal(m$answers$uses_drivers, "Yes")
  expect_equal(m$variables[[1]], "temperature_P1D")
  expect_true(model_json("base", registered, character())$baseline)
  expect_equal(model_json("base", registered, character())$contact_name, "Org")
  # A scored model nobody registered still gets a page.
  stranger <- model_json("zzz", registered, "temperature_P1D")
  expect_false(stranger$registered)
  expect_equal(stranger$long_name, "zzz")
})

test_that("the meta file describes the challenge, access and datasets", {
  cfg <- dashboard_test_config()
  cfg$public_read <- FALSE
  cfg$submissions <- list(github = list(registry = "r.csv", issue_registration = TRUE))
  variables <- dashboard_test_variables(cfg)
  now <- utc("2024-06-30")
  meta <- dashboard_meta(cfg, variables, skill_baselines(cfg),
                         list(n_forecasts = 3), now)
  expect_equal(meta$schema, dashboard_data_schema)
  expect_false(meta$access$public_read)
  expect_true(meta$challenge$github_submissions)
  expect_equal(meta$challenge$name, "Test Challenge")
  ids <- vapply(meta$variables, `[[`, "", "id")
  expect_equal(ids, c("temperature_P1D", "oxygen_P1D", "richness_P1W"))
  expect_equal(unlist(meta$variables[[3]]$windows), c(90, 180, 365))
  expect_equal(meta$groups[[1]]$plot_sites[[1]], "BBBB")
  expect_equal(vapply(meta$datasets, `[[`, "", "id"),
               c("targets", "forecasts", "summaries", "scores", "results"))
  # The data are read-only-key datasets in a private bucket; the results list
  # is published on the site either way.
  open <- vapply(meta$datasets, `[[`, logical(1), "public")
  expect_equal(open, c(FALSE, FALSE, FALSE, FALSE, TRUE))
  expect_match(meta$datasets[[2]]$urls[[1]], "project_id=testcast", fixed = TRUE)
  # Public bucket: everything is open.
  cfg$public_read <- TRUE
  open <- vapply(dashboard_meta(cfg, variables, skill_baselines(cfg), list(), now)$datasets,
                 `[[`, logical(1), "public")
  expect_true(all(open))
})

test_that("no key, secret or bucket credential reaches the staged files", {
  cfg <- dashboard_test_config()
  cfg$credentials <- list(main = list(key_env = "S3_ACCESS_KEY_ID", secret_env = "S3_SECRET_ACCESS_KEY"))
  withr::local_envvar(S3_ACCESS_KEY_ID = "AKIA-SECRET-KEY-ID", S3_SECRET_ACCESS_KEY = "super-secret-value")
  meta <- dashboard_meta(cfg, dashboard_test_variables(cfg), skill_baselines(cfg), list(), utc("2024-06-30"))
  json <- jsonlite::toJSON(meta, auto_unbox = TRUE, null = "null")
  expect_false(grepl("AKIA-SECRET-KEY-ID|super-secret-value|S3_SECRET_ACCESS_KEY", json))
})

test_that("write_dashboard_data writes every file of the contract", {
  skip_if_not_installed("arrow")
  cfg <- dashboard_test_config()
  now <- utc("2024-06-30")
  scores <- fake_scores(now) |>
    dplyr::mutate(mean = 1, `quantile02.5` = 0, `quantile97.5` = 2, observation = 1)
  summaries <- scores |> dplyr::select(-crps, -observation)
  out <- withr::local_tempdir()
  registered <- tibble::tibble(model_id = "a", long_name = "Model a", description = "x",
                               model_type = "Empirical", baseline = FALSE)
  obs <- tibble::tibble(site_id = "BBBB", variable = "temperature", duration = "P1D",
                        datetime = now - 86400 * (5:1), observation = 1:5)
  cfg$target_groups$Lakes$focal_sites <- c("AAAA", "BBBB")
  write_dashboard_data(
    cfg, out, now, inputs = list(P1D = list(summaries = lazy_table(summaries), scores = lazy_table(scores)),
                                 P1W = list(summaries = NULL, scores = NULL)),
    observations = obs, registered = registered, stats = list(n_forecasts = 1),
    variables = dashboard_test_variables(cfg))
  files <- list.files(out, recursive = TRUE)
  expect_true(all(c("meta.json", "models.json", "leaderboard/temperature_P1D.json",
                    "leaderboard/oxygen_P1D.json", "leaderboard/richness_P1W.json",
                    "forecasts/temperature_P1D__AAAA.json", "forecasts/temperature_P1D__BBBB.json",
                    "models/a.json", "models/climatology.json") %in% files))
  board <- jsonlite::read_json(file.path(out, "leaderboard", "temperature_P1D.json"))
  expect_equal(board$models$a$w[["30"]]$skill, 0.5)
  empty <- jsonlite::read_json(file.path(out, "leaderboard", "richness_P1W.json"))
  expect_length(empty$models, 0)
  meta <- jsonlite::read_json(file.path(out, "meta.json"))
  expect_equal(meta$stats$n_active_models, 3)
  index <- jsonlite::read_json(file.path(out, "models.json"))
  expect_true("a" %in% vapply(index$models, `[[`, "", "model_id"))
})

test_that("submission results are staged per model with a lookup index", {
  cfg <- dashboard_test_config()
  published <- list(
    m1 = tibble::tibble(
      model_id = "m1", file = c("a.csv", "b.csv"), source = "github:org/repo",
      first_seen = c("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"),
      status = c("processed", "invalid"), reason = c(NA, "no family"), warnings = NA_character_),
    github_7 = tibble::tibble(
      model_id = NA_character_, file = "challenge-model.yaml", source = "github:org/broken",
      first_seen = "2026-01-03T00:00:00Z", status = "registration_invalid",
      reason = "no models", warnings = NA_character_))
  testthat::local_mocked_bindings(
    remote_files = function(path) c("m1.csv", "github_7.csv", "notes.txt"),
    read_published_results = function(remote) published[[sub("[.]csv$", "", basename(remote))]])
  out <- withr::local_tempdir()
  stage_results(cfg, out)

  m1 <- jsonlite::read_json(file.path(out, "results", "m1.json"))
  expect_equal(m1$schema, dashboard_data_schema)
  expect_equal(vapply(m1$rows, `[[`, "", "file"), c("b.csv", "a.csv"))     # newest first
  expect_equal(m1$rows[[1]]$reason, "no family")
  expect_null(m1$rows[[2]]$reason)                                          # NA is left out
  index <- jsonlite::read_json(file.path(out, "results", "index.json"))$results
  expect_equal(names(index), c("m1", "github_7"))
  expect_equal(index$m1$sources[[1]], "github:org/repo")
  expect_equal(index$m1$models[[1]], "m1")
  expect_length(index$github_7$models, 0)
  expect_false(file.exists(file.path(out, "results", "notes.json")))
})

test_that("a failure to read the results warns and leaves the rest of the site alone", {
  testthat::local_mocked_bindings(remote_files = function(path) stop("no connection"))
  out <- withr::local_tempdir()
  expect_warning(stage_results(dashboard_test_config(), out), "Could not list")
  index <- jsonlite::read_json(file.path(out, "results", "index.json"))
  expect_length(index$results, 0)
})
