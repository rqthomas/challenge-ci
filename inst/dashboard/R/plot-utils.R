# A helper that renders one tab per item, for the pages that build tables and
# plots in R (targets, instructions). Sourced by R/setup.R.

# Render a panel-tabset with one tab per element of `tabs`. Each tab is a
# list with `title`, optional markdown `text`, and `widget` (a plot, a table,
# or NULL for "no data"). Call from a chunk with `results = "asis"`.
render_tabs <- function(tabs, empty = "No data are available yet.") {
  child <- c("```{r}", "if (is.null(widget)) cat(empty) else widget", "```")
  body <- purrr::map_chr(tabs, function(tab) {
    env <- new.env(parent = globalenv())
    env$widget <- tab$widget
    env$empty <- empty
    paste(c(paste("###", tab$title), "", tab$text, "",
            knitr::knit_child(text = child, envir = env, quiet = TRUE)),
          collapse = "\n")
  })
  cat("::: panel-tabset\n\n", paste(body, collapse = "\n\n"), "\n\n:::\n", sep = "")
}
