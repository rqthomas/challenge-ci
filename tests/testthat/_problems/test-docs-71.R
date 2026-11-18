# Extracted from test-docs.R:71

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "challengeci", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
config_doc <- function() {
  path <- test_path("..", "..", "docs", "configuration.md")
  skip_if_not(file.exists(path), "not running inside the repository")
  paste(readLines(path), collapse = "\n")
}
repo_config <- function() {
  path <- test_path("..", "..", "challenge_configuration.yaml")
  skip_if_not(file.exists(path), "not running inside the repository")
  yaml::read_yaml(path)
}
documented <- function(doc, keys) {
  found <- vapply(keys, function(k) grepl(paste0("`", k, "[`$]"), doc), logical(1))
  keys[!found]
}

# test -------------------------------------------------------------------------
root <- test_path("..", "..")
path <- file.path(root, "AGENTS.md")
skip_if_not(file.exists(path), "not running inside the repository")
text <- paste(readLines(path), collapse = "\n")
paths <- regmatches(text, gregexpr("`[A-Za-z_.]+(/[A-Za-z_.-]*)*`", text))[[1]]
paths <- gsub("`", "", paths)
paths <- paths[grepl("/", paths) | grepl("\\.(md|yaml|R)$", paths)]
paths <- setdiff(paths, ".Renviron")
missing <- paths[!file.exists(file.path(root, paths))]
expect_equal(missing, character(0))
funs <- unique(gsub("[`()]", "", regmatches(text, gregexpr("`[a-z_]+\\(\\)`", text))[[1]]))
exported <- getNamespaceExports("challengeci")
expect_equal(setdiff(funs, exported), character(0))
