# Reading from, listing and writing to S3 with paws.storage.
#
# A "remote path" names an object by the connection that reaches it, its bucket
# and its key: `<alias>/<bucket>/<key>`, e.g. `main/my-bucket/forecasts/a.parquet`.
# The alias is the name given to remote_connect() (by default the store's name),
# so one run can hold several connections (the main store, the submissions
# bucket read with and without a key, ...). bucket_uri(scheme = "remote") builds
# them from the config.
#
# Every write to S3 goes through upload_file(), upload_dir(), move_remote() or
# remove_remote(), so that DRY_RUN=true (see is_dry_run()) can redirect or skip
# it in one place. Uploads use this client rather than duckdb or arrow: duckdb
# >= 2.0 cannot complete S3 multipart uploads to OSN, and arrow's uploads fail
# there with XAmzContentSHA256Mismatch.

# Connections made by remote_connect(), by alias.
remote_clients <- new.env(parent = emptyenv())

# A paws S3 client for one store. A custom endpoint is addressed path-style
# (`https://endpoint/bucket/key`). Integrity checksums are sent only where the
# request needs them: paws otherwise adds one to every upload, which S3-compatible
# stores do not all accept.
s3_client <- function(endpoint, region, key = "", secret = "", anonymous = FALSE) {
  credentials <- if (anonymous) {
    list(anonymous = TRUE)
  } else {
    list(creds = list(access_key_id = key, secret_access_key = secret))
  }
  url <- if (grepl("^https?://", endpoint)) endpoint else paste0("https://", endpoint)
  paws.storage::s3(config = list(
    credentials = credentials,
    endpoint = url,
    region = region,
    s3_force_path_style = TRUE,
    max_retries = 5,
    request_checksum_calculation = "when_required"
  ))
}

# The connection for an alias, or an error that says how to make it.
remote_client <- function(alias) {
  client <- remote_clients[[alias]]
  if (is.null(client)) {
    cli::cli_abort(c(
      "No connection named {.val {alias}}.",
      "i" = "Connect first with {.fn remote_connect}."
    ))
  }
  client
}

# `<alias>/<bucket>/<key>` as its three parts.
parse_remote <- function(path) {
  parts <- strsplit(path, "/", fixed = TRUE)[[1]]
  if (length(parts) < 2 || !nzchar(parts[1]) || !nzchar(parts[2])) {
    cli::cli_abort("{.path {path}} is not a remote path, {.code alias/bucket/key}.")
  }
  list(alias = parts[1], bucket = parts[2], key = paste(parts[-(1:2)], collapse = "/"))
}

# The prefix that lists a "folder": its key with one trailing slash, so that
# `forecasts/parquet` does not also list `forecasts/parquet-old/`.
folder_prefix <- function(key) {
  if (nzchar(key)) paste0(sub("/+$", "", key), "/") else ""
}

# Every object under a folder: full key, size and ETag, following the pages S3
# lists in. A folder that does not exist is empty; errors (no such bucket, access
# denied, no network) are raised.
list_remote <- function(p) {
  client <- remote_client(p$alias)
  prefix <- folder_prefix(p$key)
  keys <- character()
  sizes <- numeric()
  etags <- character()
  token <- NULL
  repeat {
    args <- list(Bucket = p$bucket, Prefix = prefix)
    if (!is.null(token)) args$ContinuationToken <- token
    page <- do.call(client$list_objects_v2, args)
    for (object in page$Contents) {
      keys <- c(keys, object$Key)
      sizes <- c(sizes, as.numeric(object$Size))
      etags <- c(etags, gsub("\"", "", object$ETag %||% ""))
    }
    if (!isTRUE(page$IsTruncated)) break
    token <- page$NextContinuationToken
  }
  folder_marker <- endsWith(keys, "/")
  tibble::tibble(key = keys, bytes = sizes, etag = etags)[!folder_marker, ]
}

#' List the files under a remote path
#'
#' Folder markers are dropped. A prefix that does not exist gives an empty
#' result. Access or network errors are raised, never read as "no files": a
#' caller that took them for "nothing there yet" could overwrite data.
#'
#' @param path Remote path (`alias/bucket/prefix`).
#' @return A tibble with columns `path` (full remote path), `key` (relative to
#'   `path`), `bytes` and `etag` (the object's ETag: the MD5 of a file uploaded
#'   in one piece). One row per file.
#' @export
remote_files <- function(path) {
  p <- parse_remote(path)
  objects <- list_remote(p)
  prefix <- folder_prefix(p$key)
  tibble::tibble(
    path = paste(p$alias, p$bucket, objects$key, sep = "/"),
    key = substring(objects$key, nchar(prefix) + 1),
    bytes = objects$bytes,
    etag = objects$etag
  )
}

#' Connect to a store for remote reads and writes
#'
#' `remote_connect()` makes a paws S3 client for a store and files it under
#' `alias`, the first part of the remote paths that [remote_files()],
#' [upload_file()] and the others take. Do it once per store, before using them.
#' The store's region comes from [store_region()].
#'
#' @inheritParams store_credentials
#' @param alias Name for the connection. Defaults to the store name.
#' @return `alias`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' cfg <- read_config()
#' remote_connect(cfg, "main")
#' remote_files(bucket_uri(cfg, "forecasts_bucket", scheme = "remote"))
#' }
remote_connect <- function(cfg, store = "main", alias = store, anonymous = FALSE) {
  creds <- store_credentials(cfg, store, anonymous = anonymous)
  remote_clients[[alias]] <- s3_client(
    creds$endpoint, store_region(cfg, store), creds$key, creds$secret, anonymous
  )
  invisible(alias)
}

#' Does a remote object exist, and read one
#'
#' `remote_exists()` is `FALSE` for an object that is not there and an error for
#' anything else that goes wrong (access denied, no network), so a failure is
#' never taken for "not there yet". `remote_download()` copies one object to a
#' local file.
#'
#' @param path Remote path of one object (`alias/bucket/key`).
#' @param dest Local file to write.
#' @return `remote_exists()`: `TRUE` or `FALSE`. `remote_download()`: `dest`,
#'   invisibly.
#' @export
remote_exists <- function(path) {
  p <- parse_remote(path)
  client <- remote_client(p$alias)
  tryCatch({
    client$head_object(Bucket = p$bucket, Key = p$key)
    TRUE
  }, http_404 = function(e) FALSE)
}

#' @rdname remote_exists
#' @export
remote_download <- function(path, dest) {
  p <- parse_remote(path)
  body <- remote_client(p$alias)$get_object(Bucket = p$bucket, Key = p$key)$Body
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  writeBin(body, dest)
  invisible(dest)
}

# Content types for what the engine writes, so that a browser or `jsonlite`
# reading a public object gets a sensible one.
guess_content_type <- function(path) {
  ext <- tolower(tools::file_ext(sub("\\.gz$", "", path, ignore.case = TRUE)))
  gz <- grepl("\\.gz$", path, ignore.case = TRUE)
  type <- switch(ext,
    json = "application/json", csv = "text/csv", txt = "text/plain",
    parquet = "application/octet-stream", "application/octet-stream"
  )
  if (gz) "application/gzip" else type
}

# Upload one file: in one request when it is small, in parts when it is large (an
# object over 5 GB can only be uploaded in parts, and parts survive a flaky
# connection). A failed multipart upload is aborted so no parts are left billed.
remote_put_file <- function(from, to) {
  p <- parse_remote(to)
  client <- remote_client(p$alias)
  size <- file.size(from)
  type <- guess_content_type(from)
  if (size <= getOption("challengeci.multipart_threshold", 64e6)) {
    client$put_object(Bucket = p$bucket, Key = p$key, ContentType = type,
                      Body = readBin(from, "raw", size))
    return(invisible(to))
  }

  # S3 needs every part but the last to be at least 5 MiB, and allows 10,000 parts.
  part_size <- max(5 * 1024^2, ceiling(size / 9000),
                   getOption("challengeci.part_size", 32 * 1024^2))
  upload <- client$create_multipart_upload(Bucket = p$bucket, Key = p$key, ContentType = type)
  tryCatch({
    con <- file(from, "rb")
    on.exit(close(con), add = TRUE)
    parts <- list()
    repeat {
      chunk <- readBin(con, "raw", part_size)
      if (length(chunk) == 0) break
      number <- length(parts) + 1
      sent <- client$upload_part(Bucket = p$bucket, Key = p$key, UploadId = upload$UploadId,
                                 PartNumber = number, Body = chunk)
      parts[[number]] <- list(ETag = sent$ETag, PartNumber = number)
    }
    client$complete_multipart_upload(Bucket = p$bucket, Key = p$key,
                                     UploadId = upload$UploadId,
                                     MultipartUpload = list(Parts = parts))
  }, error = function(e) {
    try(client$abort_multipart_upload(Bucket = p$bucket, Key = p$key,
                                      UploadId = upload$UploadId), silent = TRUE)
    stop(e)
  })
  invisible(to)
}

# Upload a folder, file by file, replacing remote files of the same name and
# leaving other remote files alone. A file already there with the same size and
# MD5 is skipped (a file uploaded in one piece has its MD5 as its ETag), so a
# repeated run only sends what changed. Large folders upload several files at a
# time on Linux (`challengeci.upload_workers`, default 4).
remote_put_dir <- function(from, to) {
  files <- list.files(from, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  if (length(files) == 0) return(invisible(to))
  to <- sub("/+$", "", to)
  remote <- remote_files(to)
  local <- file.path(from, files)
  threshold <- getOption("challengeci.multipart_threshold", 64e6)
  at <- match(files, remote$key)
  unchanged <- !is.na(at) &
    file.size(local) == remote$bytes[at] &
    file.size(local) <= threshold &
    unname(tools::md5sum(local)) == remote$etag[at]
  todo <- files[!unchanged %in% TRUE]
  log_step("Uploading {length(todo)} of {length(files)} file{?s} to {.path {to}}")

  send <- function(file) {
    tryCatch({
      remote_put_file(file.path(from, file), paste(to, file, sep = "/"))
      NA_character_
    }, error = function(e) paste0(file, ": ", conditionMessage(e)))
  }
  workers <- getOption("challengeci.upload_workers",
                       if (identical(Sys.info()[["sysname"]], "Linux")) 4L else 1L)
  failures <- if (length(todo) > 1 && workers > 1 && .Platform$OS.type == "unix") {
    unlist(parallel::mclapply(todo, send, mc.cores = workers))
  } else {
    vapply(todo, send, character(1))
  }
  failures <- failures[!is.na(failures)]
  if (length(failures) > 0) {
    cli::cli_abort(c("{length(failures)} file{?s} did not upload:",
                     rlang::set_names(failures, "x")))
  }
  invisible(to)
}

# Move one object within a store: a server-side copy, then a delete.
remote_move <- function(from, to) {
  f <- parse_remote(from)
  t <- parse_remote(to)
  if (!identical(f$alias, t$alias)) {
    cli::cli_abort(paste("An object can only be moved within one store, not from",
                         "{.val {f$alias}} to {.val {t$alias}}."))
  }
  client <- remote_client(f$alias)
  # paws URL-encodes the copy source itself.
  client$copy_object(Bucket = t$bucket, Key = t$key, CopySource = paste0(f$bucket, "/", f$key))
  client$delete_object(Bucket = f$bucket, Key = f$key)
  invisible(to)
}

# Delete one object, or everything under a folder, 1000 keys per request.
remote_delete <- function(path, recursive = FALSE) {
  p <- parse_remote(path)
  client <- remote_client(p$alias)
  if (!recursive) {
    client$delete_object(Bucket = p$bucket, Key = p$key)
    return(invisible(path))
  }
  keys <- list_remote(p)$key
  for (batch in split(keys, ceiling(seq_along(keys) / 1000))) {
    result <- client$delete_objects(
      Bucket = p$bucket,
      Delete = list(Objects = lapply(batch, function(key) list(Key = key)), Quiet = TRUE)
    )
    if (length(result$Errors) > 0) {
      cli::cli_abort("Could not delete {length(result$Errors)} object{?s} under {.path {path}}.")
    }
  }
  invisible(path)
}

#' Upload a local file or folder, or copy it locally in a dry run
#'
#' `upload_file()` uploads one file. `upload_dir()` uploads a whole folder,
#' replacing remote files of the same name, leaving other remote files alone and
#' skipping files that are already there unchanged. In a dry run (see
#' [is_dry_run()]) both copy to [output_uri()] instead.
#'
#' A file over 64 MB is uploaded in parts of 32 MiB (the
#' `challengeci.multipart_threshold` and `challengeci.part_size` options, in
#' bytes; S3 does not take parts under 5 MiB). `upload_dir()` sends several files
#' at a time on Linux (the `challengeci.upload_workers` option, default 4).
#'
#' @param from Local file or folder.
#' @param to Remote destination (`alias/bucket/...`), e.g. from
#'   [bucket_uri()] with `scheme = "remote"`.
#' @return The destination actually written, invisibly.
#' @export
upload_file <- function(from, to) {
  if (!file.exists(from)) cli::cli_abort("{.path {from}} does not exist.")
  dest <- output_uri(to)
  if (is_dry_run()) {
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    file.copy(from, dest, overwrite = TRUE)
    cli::cli_inform("DRY RUN: wrote {.path {dest}} instead of {.path {to}}.")
  } else {
    remote_put_file(from, to)
  }
  invisible(dest)
}

#' @rdname upload_file
#' @export
upload_dir <- function(from, to) {
  if (!dir.exists(from)) cli::cli_abort("{.path {from}} is not a folder.")
  dest <- output_uri(to)
  if (is_dry_run()) {
    dir.create(dest, recursive = TRUE, showWarnings = FALSE)
    file.copy(list.files(from, full.names = TRUE), dest, recursive = TRUE,
              overwrite = TRUE)
    cli::cli_inform("DRY RUN: wrote {.path {dest}} instead of {.path {to}}.")
  } else {
    remote_put_dir(from, to)
  }
  invisible(dest)
}

#' Move or delete remote objects, or only log it in a dry run
#'
#' `move_remote()` moves one object within a store (a server-side copy, then a
#' delete). `remove_remote()` deletes one object, or with `recursive = TRUE`
#' everything under a folder.
#'
#' @param from,to Remote paths of the object and its new location.
#' @param path Remote path to delete.
#' @param recursive Delete everything under `path`.
#' @return `TRUE`, invisibly.
#' @export
move_remote <- function(from, to) {
  if (is_dry_run()) {
    cli::cli_inform("DRY RUN: would move {.path {from}} to {.path {to}}.")
  } else {
    remote_move(from, to)
  }
  invisible(TRUE)
}

#' @rdname move_remote
#' @export
remove_remote <- function(path, recursive = FALSE) {
  if (is_dry_run()) {
    cli::cli_inform("DRY RUN: would delete {.path {path}}.")
  } else {
    remote_delete(path, recursive = recursive)
  }
  invisible(TRUE)
}

#' Convert a remote path to an `s3://` URI
#'
#' @param path Remote path(s), `alias/bucket/...`.
#' @param alias The alias at the start of `path`.
#' @return Character vector of `s3://bucket/...` URIs.
#' @export
#' @examples
#' remote_to_s3("main/bucket/forecasts/a.parquet")
remote_to_s3 <- function(path, alias = "main") {
  prefix <- paste0(alias, "/")
  bad <- !startsWith(path, prefix)
  if (any(bad)) {
    cli::cli_abort("{.path {path[bad][1]}} does not start with alias {.val {alias}}.")
  }
  paste0("s3://", substring(path, nchar(prefix) + 1))
}
