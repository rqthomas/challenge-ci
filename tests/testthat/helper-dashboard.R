dashboard_test_config <- function() {
  cfg <- test_config()
  cfg$target_groups$Lakes$focal_sites <- c("BBBB", "AAAA", "CCCC")
  cfg$github_repo <- "org/challenge"
  cfg$challenge_url <- "https://example.org/challenge"
  cfg$dashboard <- list(title = "Test Challenge", n_plot_sites = 2,
                        excluded_models = list(all = "bad"))
  cfg
}

# Writes `df` as parquet and opens it with duckdb, as the staging code does.
lazy_table <- function(df) {
  path <- withr::local_tempfile(fileext = ".parquet", .local_envir = parent.frame())
  arrow::write_parquet(df, path)
  duckdbfs::open_dataset(path, recursive = FALSE)
}

utc <- function(x) as.POSIXct(x, tz = "UTC")

# The challenge's variables with names from a made-up metadata sheet.
dashboard_test_variables <- function(cfg) {
  vars <- target_variables(cfg)
  metadata <- tibble::tibble(variable = vars$variable, duration = vars$duration,
                             long_name = paste("Long", vars$variable),
                             description = paste("About", vars$variable))
  dashboard_variables(cfg, metadata)
}

# What remote_files() really returns: a tibble, not a vector of names. (Mocking it
# as a character vector once hid a bug that left the results empty.)
remote_listing <- function(keys, folder = "main/test-bucket/forecasts/submission_results") {
  tibble::tibble(path = file.path(folder, keys), key = keys,
                 bytes = rep(1, length(keys)), etag = rep("e", length(keys)))
}
