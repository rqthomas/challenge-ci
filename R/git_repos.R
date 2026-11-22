# Reading contributors' repositories with plain git, from any host.
#
# A repository is read with an anonymous, shallow, blob-less clone: the clone
# holds the latest commit and its file list (every path with its git blob SHA)
# but none of the files. A file is then fetched on its own, by SHA, when the
# submissions stage decides it is new. Tested on GitHub, GitLab.com, Bitbucket
# Cloud and Codeberg (Forgejo); any server that supports partial clones works.
#
# Why not each host's API: one code path for every host, no rate limits, and
# no credential is ever needed or sent. Two limits follow from reading with
# plain git. A file's size is not known before it is fetched (`git ls-tree -l`
# fetches every blob in a partial clone), so the size limit is applied to the
# downloaded file. And a repository is identified by its address
# (`host/owner/name`), not by a numeric id that survives renames.
#
# The registry comes from public issue text, so everything that reaches git is
# checked first: https only, a host on the allowlist
# (`submissions$repos$allowed_hosts`), no prompts, no credential helpers, no
# user git configuration, no checkout, submodules or LFS, and a time limit on
# every command.

#' Normalise a repository address
#'
#' Accepts `owner/name` (GitHub), `https://host/owner/name`, `host/owner/name`
#' and any of them with a trailing `.git` or slash. The host is lower-cased.
#' Anything else (other schemes, user names, ports, odd characters) gives `NA`.
#'
#' @param x Repository addresses.
#' @return Character vector of `host/owner/name` (a group may have
#'   subgroups, `host/group/sub/name`), `NA` where an address is not valid.
#' @export
#' @examples
#' normalize_repo(c("alice/forecasts", "https://gitlab.com/Team/sub/model.git/",
#'                  "ssh://git@github.com/a/b", "https://user@github.com/a/b"))
normalize_repo <- function(x) {
  vapply(as.character(x), normalize_one_repo, character(1), USE.NAMES = FALSE)
}

normalize_one_repo <- function(x) {
  x <- trimws(x)
  if (is.na(x) || !nzchar(x)) return(NA_character_)
  if (grepl("^https://", x, ignore.case = TRUE)) x <- sub("^https://", "", x, ignore.case = TRUE)
  # Any other scheme (http, ssh, file, git) or a git@host:path address.
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*:", x)) return(NA_character_)
  x <- sub("/+$", "", x)
  x <- sub("\\.git$", "", x)
  x <- sub("/+$", "", x)
  parts <- strsplit(x, "/", fixed = TRUE)[[1]]
  if (length(parts) == 2 && !grepl(".", parts[1], fixed = TRUE)) {
    parts <- c("github.com", parts)
  }
  if (length(parts) < 3) return(NA_character_)
  host <- tolower(parts[1])
  path <- parts[-1]
  if (!grepl("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", host)) {
    return(NA_character_)
  }
  if (!all(grepl("^[A-Za-z0-9_][A-Za-z0-9._~-]*$", path))) {
    return(NA_character_)
  }
  paste(c(host, path), collapse = "/")
}

# The https address to clone, refusing hosts that are not on the allowlist.
repo_clone_url <- function(cfg, repo) {
  host <- sub("/.*$", "", repo)
  allowed <- tolower(config_get(cfg, "submissions", "repos", "allowed_hosts",
                                default = character()))
  if (!host %in% allowed) {
    cli::cli_abort(c(
      "{.val {host}} is not an allowed git host.",
      "i" = paste("Allowed: {.val {allowed}}. A maintainer can add a host to",
                  "{.field submissions$repos$allowed_hosts}.")
    ))
  }
  paste0("https://", repo, ".git")
}

# Run git with a locked-down environment. `stdout = TRUE` returns the output
# (stdout and stderr together) with a "status" attribute on failure; a file
# path sends stdout there and returns the exit status.
git_run <- function(args, dir = NULL, stdout = TRUE, timeout = 120) {
  if (!nzchar(Sys.which("git"))) {
    cli::cli_abort("git is needed to read repositories, but was not found.")
  }
  protocols <- getOption("challengeci.git_protocols", "https")
  allow <- unlist(lapply(protocols, function(p) c("-c", paste0("protocol.", p, ".allow=always"))))
  settings <- c("-c", "protocol.allow=never", allow,
                "-c", "credential.helper=", "-c", "core.fsmonitor=false",
                "-c", "core.quotepath=false")
  if (!is.null(dir)) settings <- c("-C", dir, settings)
  env <- c("GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=true", "GIT_CONFIG_NOSYSTEM=1",
           "GIT_CONFIG_GLOBAL=/dev/null", "GIT_LFS_SKIP_SMUDGE=1", "GCM_INTERACTIVE=never")
  suppressWarnings(
    system2("git", c(settings, args), stdout = stdout, stderr = if (isTRUE(stdout)) TRUE else FALSE,
            env = env, timeout = timeout)
  )
}

git_status <- function(out) {
  if (is.numeric(out)) out else attr(out, "status") %||% 0L
}

#' Open a repository for reading
#'
#' A shallow, blob-less, anonymous clone into a temporary folder. A repository
#' that is private, missing or unreachable cannot be cloned without a
#' credential, and is reported as such. Close it with `git_close()`.
#'
#' @param url The https address to clone.
#' @param timeout Seconds allowed.
#' @return A handle: a list with `dir`, `branch` and `commit`.
#' @noRd
git_open <- function(url, timeout = 120) {
  dir <- tempfile("repo")
  out <- git_run(c("clone", "--quiet", "--depth", "1", "--filter=blob:none", "--no-checkout",
                   "--single-branch", "--no-tags", "--", url, dir), timeout = timeout)
  if (git_status(out) != 0L) {
    unlink(dir, recursive = TRUE)
    reason <- if (git_status(out) == 124L) "timed out" else "private, missing or unreachable"
    cli::cli_abort("the repository could not be cloned anonymously ({reason})")
  }
  one <- function(args) {
    res <- git_run(args, dir = dir)
    if (git_status(res) != 0L || length(res) == 0) NA_character_ else res[1]
  }
  list(dir = dir, branch = one(c("rev-parse", "--abbrev-ref", "HEAD")),
       commit = one(c("rev-parse", "HEAD")))
}

git_close <- function(handle) {
  if (!is.null(handle$dir)) unlink(handle$dir, recursive = TRUE)
  invisible(NULL)
}

# Every file at the tip, with its blob SHA. Sizes are not known without
# fetching the blobs, so `size` is NA. Submodules and quoted (unusual) paths
# are left out.
git_tree <- function(handle) {
  out <- git_run(c("ls-tree", "-r", "HEAD"), dir = handle$dir)
  if (git_status(out) != 0L) cli::cli_abort("could not list the repository's files")
  m <- regmatches(out, regexec("^([0-9]+) (blob|tree|commit) ([0-9a-f]{40,64})\t(.*)$", out))
  m <- m[lengths(m) == 5]
  tibble::tibble(
    path = vapply(m, `[`, character(1), 5),
    type = vapply(m, `[`, character(1), 3),
    sha = vapply(m, `[`, character(1), 4),
    size = rep(NA_real_, length(m))
  ) |>
    dplyr::filter(.data$type == "blob", !startsWith(.data$path, "\""))
}

# Fetch one file by its blob SHA (a blob never changes, so this is exactly the
# file that was listed even if the branch has moved on).
git_blob <- function(handle, sha, dest, timeout = 300) {
  stopifnot(grepl("^[0-9a-f]{40,64}$", sha))
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  status <- git_status(git_run(c("cat-file", "blob", sha), dir = handle$dir, stdout = dest,
                               timeout = timeout))
  if (status != 0L) {
    unlink(dest)
    reason <- if (status == 124L) "timed out" else "failed"
    cli::cli_abort("could not fetch file {.val {sha}} ({reason})")
  }
  invisible(dest)
}

# A small text file by SHA (refusing anything over `max_bytes`).
git_text <- function(handle, sha, max_bytes = 1e6) {
  path <- tempfile()
  on.exit(unlink(path))
  git_blob(handle, sha, path)
  if (file.size(path) > max_bytes) {
    cli::cli_abort("the file is larger than {round(max_bytes / 1e6)} MB")
  }
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Git LFS stores a large file as a small text pointer in the repository. Such a
# pointer is not the forecast, and cannot be fetched without LFS.
is_lfs_pointer <- function(path) {
  if (file.size(path) > 1024) return(FALSE)
  first <- tryCatch(readLines(path, n = 1, warn = FALSE), error = function(e) "")
  pointer <- "version https://git-lfs.github.com/spec"
  length(first) == 1 && !is.na(first) && startsWith(first, pointer)
}
