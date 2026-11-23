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
# Hugging Face (and any repository that uses Git LFS) stores large and
# compressed files as small pointer files. A pointer is resolved through the
# host's public Git LFS download API (see git_lfs_download()), so a
# `forecast.csv.gz` on huggingface.co is read like any other file.
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
       commit = one(c("rev-parse", "HEAD")), url = url)
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
# file that was listed even if the branch has moved on). A Git LFS pointer is
# replaced by the file it stands for, unless that file is bigger than
# `max_bytes`, when the pointer is left for process_submission() to report.
git_blob <- function(handle, sha, dest, timeout = 300, max_bytes = Inf) {
  stopifnot(grepl("^[0-9a-f]{40,64}$", sha))
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  status <- git_status(git_run(c("cat-file", "blob", sha), dir = handle$dir, stdout = dest,
                               timeout = timeout))
  if (status != 0L) {
    unlink(dest)
    reason <- if (status == 124L) "timed out" else "failed"
    cli::cli_abort("could not fetch file {.val {sha}} ({reason})")
  }
  pointer <- lfs_pointer(dest)
  if (!is.null(pointer) && pointer$size <= max_bytes) {
    git_lfs_download(handle$url, pointer, dest, timeout = timeout)
  }
  invisible(dest)
}

# A small text file by SHA (refusing anything over `max_bytes`).
git_text <- function(handle, sha, max_bytes = 1e6) {
  path <- tempfile()
  on.exit(unlink(path))
  git_blob(handle, sha, path, max_bytes = max_bytes)
  if (file.size(path) > max_bytes) {
    cli::cli_abort("the file is larger than {round(max_bytes / 1e6)} MB")
  }
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

# Git LFS stores a large file as a small text pointer in the repository:
#   version https://git-lfs.github.com/spec/v1
#   oid sha256:<64 hex digits>
#   size <bytes>
# Returns list(oid, size) for a pointer file, NULL for anything else.
lfs_pointer <- function(path) {
  if (file.size(path) > 1024) return(NULL)
  lines <- tryCatch(readLines(path, n = 5, warn = FALSE), error = function(e) character())
  if (length(lines) < 3 || !startsWith(lines[1], "version https://git-lfs.github.com/spec")) {
    return(NULL)
  }
  oid <- sub("^oid sha256:([0-9a-f]{64})$", "\\1", lines[grepl("^oid sha256:", lines)])
  size <- sub("^size ([0-9]+)$", "\\1", lines[grepl("^size ", lines)])
  if (length(oid) != 1 || !grepl("^[0-9a-f]{64}$", oid) || length(size) != 1 ||
        !grepl("^[0-9]+$", size)) {
    return(NULL)
  }
  list(oid = oid, size = as.numeric(size))
}

is_lfs_pointer <- function(path) !is.null(lfs_pointer(path))

# Download the file a Git LFS pointer stands for, through the host's Git LFS
# batch API, which serves public repositories without a credential (GitHub,
# GitLab, Bitbucket, Codeberg and Hugging Face all do). The host answers with a
# download address, usually on its storage or CDN, which must be https. The file
# is checked against the pointer's size and SHA-256.
git_lfs_download <- function(url, pointer, dest, timeout = 300) {
  if (is.null(url)) {
    cli::cli_abort("cannot resolve a Git LFS pointer without the repository address")
  }
  lfs <- "application/vnd.git-lfs+json"
  batch <- httr2::request(paste0(sub("/+$", "", url), "/info/lfs/objects/batch")) |>
    httr2::req_headers(Accept = lfs, `Content-Type` = lfs) |>
    httr2::req_user_agent("challengeci (https://github.com/eco4cast/challenge-ci)") |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_body_json(list(operation = "download", transfers = list("basic"),
                              objects = list(list(oid = pointer$oid, size = pointer$size)))) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  answer <- tryCatch(httr2::resp_body_json(batch), error = function(e) list())
  object <- answer$objects[[1]]
  refused <- httr2::resp_status(batch) >= 400 || !is.null(object$error) ||
    is.null(object$actions$download)
  if (refused) {
    reason <- object$error$message %||% answer$message %||%
      paste("HTTP", httr2::resp_status(batch))
    cli::cli_abort("the host would not serve the Git LFS file ({reason})")
  }
  action <- object$actions$download
  if (!grepl("^https://", action$href)) {
    cli::cli_abort("the host gave a Git LFS download address that is not https")
  }
  # Into a new file first: the pointer stays in `dest` unless the real file is good.
  fetched <- tempfile()
  on.exit(unlink(fetched), add = TRUE)
  lfs_fetch_file(action$href, action$header %||% list(), fetched, timeout)
  digest <- local({
    con <- file(fetched, "rb")
    on.exit(close(con))
    # (as.character() keeps the "hash" class, which identical() would see.)
    as.vector(as.character(openssl::sha256(con)))
  })
  if (file.size(fetched) != pointer$size || !identical(digest, pointer$oid)) {
    cli::cli_abort("the Git LFS file did not match its pointer (size or SHA-256)")
  }
  file.copy(fetched, dest, overwrite = TRUE)
  invisible(dest)
}

# The download itself (a function of its own so that tests can stand in for it).
lfs_fetch_file <- function(href, headers, path, timeout) {
  httr2::request(href) |>
    httr2::req_headers(!!!headers) |>
    httr2::req_user_agent("challengeci (https://github.com/eco4cast/challenge-ci)") |>
    httr2::req_timeout(timeout) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform(path = path)
  invisible(path)
}
