# Install the packages the package's DESCRIPTION lists under Depends and Imports
# that the image lacks, or has in a version older than the `(>= x)` it asks for.
# The engine's image is built from main, so a pull request that adds or raises a
# dependency is tested before the image has it. Installed packages that are new
# enough are left alone (nothing else is upgraded: the image's versions are
# deliberate).
#
# Usage: Rscript .github/scripts/install-missing-deps.R [path of the package]
path <- commandArgs(trailingOnly = TRUE)[1]
deps <- desc::desc_get_deps(if (is.na(path)) "." else path)
deps <- deps[deps$type %in% c("Depends", "Imports") & deps$package != "R", ]

satisfied <- mapply(function(pkg, version) {
  if (!requireNamespace(pkg, quietly = TRUE)) return(FALSE)
  version == "*" || utils::packageVersion(pkg) >= sub("^>=\\s*", "", version)
}, deps$package, deps$version)

missing <- deps$package[!satisfied]
cat("Installing:", if (length(missing) > 0) paste(missing, collapse = ", ") else "nothing", "\n")
if (length(missing) > 0) install.packages(missing)
