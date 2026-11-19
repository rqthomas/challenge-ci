# Shared setup for every dashboard page. render_dashboard() builds the site in
# a temporary folder (the template plus the challenge's content) and renders it
# with these environment variables set:
#   CHALLENGE_CONFIG    absolute path of the challenge's config
#   CHALLENGECI_SOURCE  the package source folder, when rendering from a
#                       development copy (pkgload); unset when installed
# The staged data are in data/ next to the pages.

knitr::opts_chunk$set(echo = FALSE, message = FALSE, warning = FALSE)
source_dir <- Sys.getenv("CHALLENGECI_SOURCE")
if (nzchar(source_dir)) {
  pkgload::load_all(source_dir, quiet = TRUE)
} else {
  library(challengeci)
}
suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})
source("R/plot-utils.R")

cfg <- read_config(Sys.getenv("CHALLENGE_CONFIG", "challenge_configuration.yaml"),
                   validate = FALSE)
settings <- dashboard_settings(cfg)

data_file <- function(name) {
  path <- file.path("data", name)
  if (!file.exists(path)) stop("Missing ", path, ". Build the site with render_dashboard().")
  path
}

variables <- readr::read_csv(data_file("variables.csv"), show_col_types = FALSE)
variables$tab_title <- paste0(variables$group, ": ", gsub("_", " ", variables$long_name))

# Model ids not to plot for a variable.
excluded_models <- function(variable) {
  unique(unlist(settings$excluded_models[c("all", variable)]))
}

# Markdown from the challenge's _content/ folder, or nothing if it has none.
# For use in a chunk with `results = "asis"`.
include_content <- function(file) {
  path <- file.path("_content", file)
  if (file.exists(path)) cat(readLines(path, warn = FALSE), sep = "\n")
}

# Links used across pages.
links <- list(
  sites = stac_browser_url(cfg, "sites/collection.json"),
  forecasts = stac_browser_url(cfg, "forecasts/collection.json"),
  summaries = stac_browser_url(cfg, "summaries/collection.json"),
  scores = stac_browser_url(cfg, "scores/collection.json"),
  noaa = stac_browser_url(cfg, "noaa_forecasts/collection.json"),
  catalog = stac_browser_url(cfg),
  docs = cfg$catalog_config$documentation_url %||% cfg$challenge_url
)
