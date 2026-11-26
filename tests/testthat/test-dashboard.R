test_that("dashboard settings have defaults the config can override", {
  s <- dashboard_settings(dashboard_test_config())
  expect_equal(s$n_plot_sites, 2)
  expect_equal(s$leaderboard_max_horizon, 35)
  expect_equal(s$excluded_models$all, "bad")
})

test_that("extra pages from the config reach the navigation", {
  cfg <- dashboard_test_config()
  cfg$dashboard$extra_pages <- list(list(href = "learn-more.qmd"),
                                    list(href = "about.qmd", title = "About us"))
  nav <- dashboard_nav(cfg)
  expect_equal(vapply(nav, `[[`, "", "href")[7:8], c("learn-more.html", "about.html"))
  expect_equal(vapply(nav, `[[`, "", "title")[7:8], c("Learn more", "About us"))
  dir <- withr::local_tempdir()
  # The page's own title is used when the config gives none.
  writeLines(c("---", "title: \"Learn more about us\"", "---", "Text"), file.path(dir, "learn-more.qmd"))
  expect_equal(dashboard_nav(cfg, dir)[[7]]$title, "Learn more about us")
  write_dashboard_shell(cfg, dir, banner = TRUE)
  header <- paste(readLines(file.path(dir, "_header.html")), collapse = "\n")
  expect_match(header, "learn-more.html", fixed = TRUE)
  expect_match(header, "Learn more about us", fixed = TRUE)
  expect_match(header, "Test Challenge", fixed = TRUE)
  expect_match(header, "hub-banner", fixed = TRUE)
  expect_match(paste(readLines(file.path(dir, "_footer.html")), collapse = "\n"),
               "https://github.com/org/challenge", fixed = TRUE)
})

test_that("weekly variables look back a year, others 30 days", {
  expect_equal(dashboard_lookback_days(c("P1D", "PT30M", "P1W", "P1M")), c(30, 30, 365, 365))
})

test_that("plot_sites() takes the first focal sites of each group", {
  sites <- plot_sites(dashboard_test_config())
  expect_equal(unique(sites$site_id), c("BBBB", "AAAA"))
  expect_setequal(sites$variable, c("temperature", "oxygen"))
})

test_that("latest_forecasts() keeps the newest settled forecast at plot sites", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-10")
  summaries <- tidyr::expand_grid(
    model_id = "m", site_id = c("AAAA", "ZZZZ"), variable = "temperature",
    reference_datetime = utc(c("2024-06-01", "2024-06-05", "2024-06-09")),
    lead = 0:2
  ) |>
    dplyr::mutate(datetime = reference_datetime + lead * 86400, mean = 1,
                  quantile02.5 = 0, quantile97.5 = 2) |>
    dplyr::select(-lead)
  sites <- tibble::tibble(variable = "temperature", site_id = "AAAA")
  out <- latest_forecasts(lazy_table(summaries), sites, now)
  # 2024-06-09 is too recent (less than two days old); horizon 0 is dropped.
  expect_equal(unique(as.Date(out$reference_datetime)), as.Date("2024-06-05"))
  expect_equal(unique(out$site_id), "AAAA")
  expect_equal(nrow(out), 2)
})

test_that("settle_days sets how old the latest forecast must be", {
  skip_if_not_installed("arrow")
  summaries <- tidyr::expand_grid(
    model_id = "m", site_id = "AAAA", variable = "temperature",
    reference_datetime = utc(c("2024-06-01", "2024-06-05", "2024-06-08", "2024-06-09")),
    lead = 0:2
  ) |>
    dplyr::mutate(datetime = reference_datetime + lead * 86400, mean = 1,
                  quantile02.5 = 0, quantile97.5 = 2) |>
    dplyr::select(-lead)
  sites <- tibble::tibble(variable = "temperature", site_id = "AAAA")
  newest <- function(now, days) {
    out <- latest_forecasts(lazy_table(summaries), sites, utc(now), days)
    format(max(as.Date(out$reference_datetime)))
  }
  expect_equal(newest("2024-06-10", 0), "2024-06-09")    # nothing to wait for
  expect_equal(newest("2024-06-10", 2), "2024-06-05")    # the default
  expect_equal(newest("2024-06-10", 6), "2024-06-01")
  # A forecast for reference date D is shown by the first update on day D + settle_days,
  # whatever the hour (an update is never exactly at midnight): D = 8 June, 2 days.
  expect_equal(newest("2024-06-10 03:17:00", 2), "2024-06-08")
  expect_equal(newest("2024-06-09 23:59:00", 2), "2024-06-05")   # the day before: not yet
  expect_equal(newest("2024-06-10 03:17:00", 3), "2024-06-05")   # a longer wait: one day later
  # The default is 2, as before the setting existed.
  expect_equal(dashboard_settings(list())$settle_days, 2)
})

test_that("dashboard$settle_days is a whole number of days and reaches the meta file", {
  cfg <- test_config()
  errors <- function(x) {
    cfg$dashboard$settle_days <- x
    p <- config_problems(cfg)
    p$message[p$severity == "error" & p$key == "dashboard$settle_days"]
  }
  for (ok in list(NULL, 0, 2, 3, 30)) expect_length(errors(ok), 0)
  for (bad in list(-1, 1.5, 31, "two", c(2, 3), NA)) {
    expect_match(errors(bad), "whole number of days", info = deparse(bad))
  }
  cfg <- dashboard_test_config()
  cfg$dashboard$settle_days <- 3
  meta <- dashboard_meta(cfg, dashboard_test_variables(cfg), skill_baselines(cfg),
                         list(), utc("2024-06-30"))
  expect_equal(meta$settle_days, 3)
  cfg$dashboard$settle_days <- NULL
  expect_equal(dashboard_meta(cfg, dashboard_test_variables(cfg), skill_baselines(cfg),
                              list(), utc("2024-06-30"))$settle_days, 2)
})

test_that("latest_forecasts() falls back to the newest forecast for a new challenge", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-10")
  summaries <- tidyr::expand_grid(
    model_id = "m", site_id = "AAAA", variable = c("temperature", "oxygen"),
    reference_datetime = utc(c("2024-06-09", "2024-06-10")), lead = 1:2
  ) |>
    dplyr::mutate(datetime = reference_datetime + lead * 86400, mean = 1,
                  quantile02.5 = 0, quantile97.5 = 2) |>
    dplyr::select(-lead)
  # Temperature also has an old forecast; oxygen has only recent ones.
  old <- dplyr::filter(summaries, variable == "temperature") |>
    dplyr::mutate(reference_datetime = utc("2024-06-01"), datetime = reference_datetime + 86400)
  summaries <- dplyr::bind_rows(summaries, old)
  sites <- tibble::tibble(variable = c("temperature", "oxygen"), site_id = "AAAA")
  out <- latest_forecasts(lazy_table(summaries), sites, now)
  newest <- dplyr::summarise(out, ref = format(as.Date(max(reference_datetime))), .by = variable)
  expect_equal(newest$ref[newest$variable == "temperature"], "2024-06-01")  # the settled one
  expect_equal(newest$ref[newest$variable == "oxygen"], "2024-06-10")       # nothing older: newest
})

test_that("scored_forecasts() picks the latest forecast old enough to have observations", {
  skip_if_not_installed("arrow")
  now <- utc("2024-06-30")
  scores <- tibble::tibble(
    model_id = "m", site_id = "AAAA", variable = "temperature",
    reference_datetime = utc(c("2024-05-01", "2024-05-25", "2024-06-20")),
    datetime = reference_datetime + 86400, mean = 1, quantile02.5 = 0, quantile97.5 = 2,
    observation = c(1, 1, NA)
  )
  sites <- tibble::tibble(variable = "temperature", site_id = "AAAA")
  out <- scored_forecasts(lazy_table(scores), sites, now, lookback = 30)
  expect_equal(as.Date(out$reference_datetime), as.Date("2024-05-25"))
})

test_that("model types group differently written answers", {
  expect_equal(model_type_label(c("empirical (a statistical model)",
                                  "Empirical (a statistical model)", NA, "Process based")),
               c("Empirical", "Empirical", "Not described", "Process based"))
})

test_that("dashboard_sites() marks which groups each site belongs to", {
  sites <- dashboard_sites(dashboard_test_config())
  expect_equal(sites$Lakes, c(TRUE, TRUE, FALSE))
  expect_equal(sites$Birds, c(FALSE, TRUE, TRUE))
})

test_that("the Quarto site settings come from the config", {
  path <- withr::local_tempfile(fileext = ".yml")
  write_quarto_metadata(dashboard_test_config(), path)
  expect_equal(yaml::read_yaml(path)$format$html$css, "styles.css")
  site <- yaml::read_yaml(path)$website
  expect_equal(site$title, "Test Challenge")
  expect_equal(site$`repo-url`, "https://github.com/org/challenge")
  expect_equal(site$`site-url`, "https://example.org/challenge")
})

test_that("stac_browser_url() points at the catalog repository", {
  cfg <- list(catalog_config = list(catalog_repo = "org/cat"))
  expect_equal(stac_browser_url(cfg, "sites/collection.json"),
               paste0("https://radiantearth.github.io/stac-browser/#/external/",
                      "raw.githubusercontent.com/org/cat/main/sites/collection.json"))
})

test_that("the catalog is linked on the branch it is committed to", {
  # A catalog branch of the challenge's own repository.
  cfg <- list(github_repo = "org/challenge", catalog_config = list(catalog_branch = "catalog"))
  expect_equal(catalog_raw_url(cfg, "forecasts/collection.json"),
               "https://raw.githubusercontent.com/org/challenge/catalog/forecasts/collection.json")
  expect_equal(stac_browser_url(cfg),
               paste0("https://radiantearth.github.io/stac-browser/#/external/",
                      "raw.githubusercontent.com/org/challenge/catalog/catalog.json"))
  # A repository of its own keeps its default branch, `main`.
  own <- list(catalog_config = list(catalog_repo = "org/cat"))
  expect_equal(catalog_raw_url(own, "catalog.json"),
               "https://raw.githubusercontent.com/org/cat/main/catalog.json")
  # Both can be set.
  both <- list(catalog_config = list(catalog_repo = "org/cat", catalog_branch = "stac"))
  expect_equal(catalog_raw_url(both, "catalog.json"),
               "https://raw.githubusercontent.com/org/cat/stac/catalog.json")
})

test_that("dashboard pages call only exported functions", {
  # Pages run with library(challengeci); internal functions work under
  # pkgload but fail on the installed package.
  dir <- system.file("dashboard", package = "challengeci")
  files <- list.files(dir, "[.](qmd|R)$", recursive = TRUE, full.names = TRUE, all.files = TRUE)
  text <- unlist(lapply(files, readLines))
  calls <- unique(unlist(regmatches(
    text, gregexpr("\\b[A-Za-z_][A-Za-z0-9_.]*(?=\\()", text, perl = TRUE)
  )))
  internal <- setdiff(intersect(calls, ls(asNamespace("challengeci"), all.names = TRUE)),
                      getNamespaceExports("challengeci"))
  expect_equal(internal, character(0))
})

test_that("empty dashboard tables bind with real ones", {
  for (part in c("forecasts", "analysis")) {
    expect_equal(nrow(empty_dashboard_table(part)), 0)
  }
  expect_true("observation" %in% names(empty_dashboard_table("analysis")))
  expect_s3_class(empty_dashboard_table("forecasts")$reference_datetime, "POSIXct")
})

test_that("the browser modules never write HTML and every import resolves", {
  dir <- system.file("dashboard", "js", package = "challengeci")
  files <- list.files(dir, "[.]js$", recursive = TRUE, full.names = TRUE)
  expect_gt(length(files), 5)
  for (f in files) {
    code <- paste(readLines(f), collapse = "\n")
    # Data from the files (model names, reasons) must only ever become text.
    expect_false(grepl("innerHTML|outerHTML|insertAdjacentHTML|document\\.write|eval\\(|new Function",
                       code), info = f)
    imports <- regmatches(code, gregexpr("from '(\\.[^']+)'", code))[[1]]
    for (i in sub("from '(.*)'", "\\1", imports)) {
      expect_true(file.exists(normalizePath(file.path(dirname(f), i), mustWork = FALSE)),
                  info = paste(basename(f), "imports", i))
    }
  }
})

test_that("every page module has a Quarto page, and no page is left without one", {
  dir <- system.file("dashboard", package = "challengeci")
  modules <- sub("[.]js$", "", list.files(file.path(dir, "js", "pages"), "[.]js$"))
  pages <- list.files(dir, "[.]qmd$")
  used <- unlist(lapply(file.path(dir, pages), function(f) {
    text <- paste(readLines(f), collapse = "\n")
    sub(".*js/pages/([a-z]+)[.]js.*", "\\1", regmatches(text, regexpr("js/pages/[a-z]+[.]js", text)))
  }))
  expect_setequal(used, modules)
  # Every page the navigation links to is rendered from a .qmd.
  hrefs <- sub("[.]html$", ".qmd", vapply(dashboard_pages, `[[`, "", "href"))
  expect_true(all(hrefs %in% pages))
})
