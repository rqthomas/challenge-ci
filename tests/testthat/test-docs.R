# docs/configuration.md must describe every key the config uses. These tests
# fail when a key is added to the config without documenting it.

config_doc <- function() {
  path <- test_path("..", "..", "docs", "configuration.md")
  skip_if_not(file.exists(path), "not running inside the repository")
  paste(readLines(path), collapse = "\n")
}

# A complete challenge config: every key it uses must be documented.
repo_config <- function() {
  yaml::read_yaml(test_path("fixtures", "full_config.yaml"))
}

# Keys missing from the doc. A key counts as documented when it appears in
# backticks on its own (`sites`) or as the start of a path (`sites$columns`).
documented <- function(doc, keys) {
  found <- vapply(keys, function(k) grepl(paste0("`", k, "[`$]"), doc), logical(1))
  keys[!found]
}

test_that("every top-level config key is documented", {
  doc <- config_doc()
  keys <- names(repo_config())
  expect_equal(documented(doc, keys), character(0))
})

test_that("every target group and catalog key is documented", {
  doc <- config_doc()
  cfg <- repo_config()
  group_keys <- unique(unlist(lapply(cfg$target_groups, names)))
  # Keys may appear in a list, e.g. `forecasts_thumbnail`, `scores_thumbnail`.
  keys <- c(group_keys, names(cfg$catalog_config))
  expect_equal(documented(doc, keys), character(0))
})

test_that("the workflows are valid YAML", {
  dir <- test_path("..", "..", ".github", "workflows")
  skip_if_not(dir.exists(dir), "not running inside the repository")
  for (f in list.files(dir, "\\.ya?ml$", full.names = TRUE)) {
    # suppressWarnings: R's parser warns about `context: .`, which is valid YAML.
    expect_no_error(suppressWarnings(yaml::read_yaml(f)))
  }
})

test_that("AGENTS.md names paths and functions that exist", {
  root <- test_path("..", "..")
  path <- file.path(root, "AGENTS.md")
  skip_if_not(file.exists(path), "not running inside the repository")
  text <- paste(readLines(path), collapse = "\n")

  # Repository paths in backticks, e.g. `R/` or `docs/operations.md`.
  paths <- regmatches(text, gregexpr("`[A-Za-z_.]+(/[A-Za-z_.-]*)*`", text))[[1]]
  paths <- gsub("`", "", paths)
  paths <- paths[grepl("/", paths) | grepl("\\.(md|yaml|R)$", paths)]
  paths <- setdiff(paths, ".Renviron")
  missing <- paths[!file.exists(file.path(root, paths))]
  expect_equal(missing, character(0))

  # Package functions in backticks, e.g. `upload_file()`.
  funs <- unique(gsub("[`()]", "", regmatches(text, gregexpr("`[a-z_]+\\(\\)`", text))[[1]]))
  exported <- getNamespaceExports("challengeci")
  expect_equal(setdiff(funs, exported), character(0))
})
