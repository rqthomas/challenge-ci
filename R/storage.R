# Connecting to the challenge's S3 stores and building paths inside them.
#
# A "store" is one S3 endpoint plus the credentials for it:
#   main         forecasts, scores, targets, archive, metadata (config `endpoint`)
#   submissions  where participants upload forecasts (`submissions_endpoint`)
#   noaa         NOAA driver forecasts (`noaa_endpoint`; main credentials)
#   scratch      temporary files used while scoring (`scratch$endpoint`)
# Credentials come from environment variables whose names are set in the
# config's `credentials` block (see config_defaults()).

store_names <- c("main", "submissions", "noaa", "scratch")

#' Endpoint and credentials for a store
#'
#' @inheritParams config_get
#' @param store One of `"main"`, `"submissions"`, `"noaa"` or `"scratch"`.
#' @param anonymous If `TRUE`, return empty credentials for public read-only
#'   access instead of reading environment variables.
#' @return `store_credentials()`: a list with `endpoint`, `key` and `secret`.
#'   `has_credentials()`: whether both environment variables are set.
#' @export
store_credentials <- function(cfg, store = "main", anonymous = FALSE) {
  store <- rlang::arg_match(store, store_names)
  endpoint <- switch(store,
    main = config_get(cfg, "endpoint"),
    submissions = config_get(cfg, "submissions_endpoint"),
    noaa = config_get(cfg, "noaa_endpoint", default = cfg$endpoint),
    scratch = config_get(cfg, "scratch", "endpoint")
  )
  if (anonymous) return(list(endpoint = endpoint, key = "", secret = ""))

  # NOAA drivers live in the main store unless the config says otherwise.
  env <- cfg$credentials[[store]] %||% cfg$credentials$main
  key <- Sys.getenv(env$key_env)
  secret <- Sys.getenv(env$secret_env)
  if (!nzchar(key) || !nzchar(secret)) {
    cli::cli_abort(c(
      "No credentials for the {.val {store}} store.",
      "i" = paste("Set {.envvar {env$key_env}} and {.envvar {env$secret_env}},",
                  "or use {.code anonymous = TRUE} for public reads.")
    ))
  }
  list(endpoint = endpoint, key = key, secret = secret)
}

#' @rdname store_credentials
#' @export
has_credentials <- function(cfg, store = "main") {
  store <- rlang::arg_match(store, store_names)
  env <- cfg$credentials[[store]] %||% cfg$credentials$main
  nzchar(Sys.getenv(env$key_env)) && nzchar(Sys.getenv(env$secret_env))
}

#' Whether reads of the main store go without a key
#'
#' A public challenge's forecasts, scores and targets can be read anonymously,
#' and the engine does so (a dry run then needs no secrets). With
#' `public_read: false` in the config, every read of the main store uses its
#' credentials instead, so the buckets can stay private. This covers the main
#' store only: NOAA driver data is read as before.
#'
#' @inheritParams config_get
#' @return `TRUE` when the main store is read anonymously.
#' @export
#' @examples
#' anonymous_reads(list(public_read = FALSE))
anonymous_reads <- function(cfg) {
  !isFALSE(cfg$public_read)
}

# Anonymous if the store is public and there is no key (public stores can be
# read without one; a private store always needs it).
read_anonymously_without_key <- function(cfg) {
  anonymous_reads(cfg) && !has_credentials(cfg, "main")
}

#' Region of a store
#'
#' S3 requests are signed for a region, and some providers reject the wrong
#' one. The region is the config's `region` when set; for a Backblaze B2
#' endpoint (`s3.<region>.backblazeb2.com`) it is read from the endpoint; and
#' otherwise it is `us-east-1`, which stores that ignore the region (such as
#' OSN) accept.
#'
#' @inheritParams store_credentials
#' @return The region, a character scalar.
#' @export
#' @examples
#' cfg <- list(endpoint = "s3.us-east-005.backblazeb2.com")
#' store_region(cfg)
store_region <- function(cfg, store = "main") {
  endpoint <- store_credentials(cfg, store, anonymous = TRUE)$endpoint
  match <- regmatches(endpoint, regexec("^s3\\.([a-z0-9-]+)\\.backblazeb2\\.com$", endpoint))[[1]]
  cfg$region %||% (if (length(match) == 2) match[2]) %||% "us-east-1"
}

#' Connect to a store
#'
#' `s3_connect()` connects a store for both kinds of access. [remote_connect()]
#' makes the S3 client that [remote_files()], [upload_file()] and the like use,
#' filed under an alias that is the first part of their remote paths.
#' `duckdb_connect()` registers a duckdb secret so that `duckdbfs` can read and
#' write `s3://` paths in the store.
#'
#' Each duckdb secret is scoped to the store's bucket, so one connection can
#' hold secrets for several stores (for example main and scratch while
#' scoring). duckdbfs names a secret after its key, so two anonymous
#' connections on the same duckdb connection replace each other.
#'
#' @inheritParams store_credentials
#' @param alias Name for the remote connection. Defaults to the store name.
#' @param conn duckdb connection. Defaults to duckdbfs's cached connection.
#' @return `s3_connect()`: the alias, invisibly. `duckdb_connect()`: `conn`,
#'   invisibly.
#' @export
#' @examples
#' \dontrun{
#' cfg <- read_config()
#' s3_connect(cfg, "main")
#' remote_files(bucket_uri(cfg, "forecasts_bucket", scheme = "remote"))
#' }
s3_connect <- function(cfg, store = "main", alias = store, anonymous = FALSE,
                       conn = duckdbfs::cached_connection()) {
  remote_connect(cfg, store, alias = alias, anonymous = anonymous)
  duckdb_connect(cfg, store, anonymous = anonymous, conn = conn)
  invisible(alias)
}

#' @rdname s3_connect
#' @export
duckdb_connect <- function(cfg, store = "main", anonymous = FALSE,
                           conn = duckdbfs::cached_connection()) {
  creds <- store_credentials(cfg, store, anonymous = anonymous)
  duckdbfs::duckdb_secrets(
    key = creds$key,
    secret = creds$secret,
    endpoint = creds$endpoint,
    region = store_region(cfg, store),
    bucket = store_bucket(cfg, store),
    url_compatibility_mode = FALSE,
    conn = conn
  )
  invisible(conn)
}

#' Build a path inside one of the challenge's buckets
#'
#' Bucket settings in the config (`forecasts_bucket`, `scores_bucket`, ...)
#' hold a bucket name followed by a prefix, e.g.
#' `bio230014-bucket01/challenges/forecasts`. `bucket_uri()` adds further path
#' parts and formats the result for the tool that will use it.
#'
#' @inheritParams config_get
#' @param key Name of the config setting holding the bucket path, such as
#'   `"forecasts_bucket"`. Use `"scratch"` for the scoring scratch bucket.
#' @param ... Path parts to add, e.g. `"bundled-parquet"`, `"project_id=x"`.
#' @param scheme `"s3"` for duckdb and arrow (`s3://bucket/...`), `"remote"` for
#'   [remote_files()], [upload_file()] and the like (`alias/bucket/...`), or
#'   `"https"` for public URLs.
#' @param alias The remote connection's alias, for `scheme = "remote"`. Defaults to the
#'   bucket's store name, which is the alias [remote_connect()] sets by default.
#' @return A character scalar.
#' @export
#' @examples
#' cfg <- list(endpoint = "sdsc.osn.xsede.org",
#'             forecasts_bucket = "bucket01/challenges/forecasts")
#' bucket_uri(cfg, "forecasts_bucket", "bundled-parquet")
#' bucket_uri(cfg, "forecasts_bucket", "bundled-parquet", scheme = "remote")
#' bucket_uri(cfg, "forecasts_bucket", scheme = "https")
bucket_uri <- function(cfg, key, ..., scheme = c("s3", "remote", "https"),
                       alias = NULL) {
  scheme <- rlang::arg_match(scheme)
  path <- paste(c(bucket_path(cfg, key), ...), collapse = "/")
  path <- gsub("/+", "/", gsub("^/|/$", "", path))
  store <- bucket_key_store(key)
  switch(scheme,
    s3 = paste0("s3://", path),
    remote = paste0(alias %||% store, "/", path),
    https = paste0("https://", store_credentials(cfg, store, anonymous = TRUE)$endpoint,
                   "/", path)
  )
}

#' An arrow S3 file system rooted in one of the challenge's buckets
#'
#' Use this for reading with arrow (e.g. `arrow::open_dataset()`). Upload with
#' [upload_file()] instead, because arrow's S3 uploads fail on OSN with
#' `XAmzContentSHA256Mismatch`.
#'
#' @inheritParams bucket_uri
#' @inheritParams store_credentials
#' @return An arrow `SubTreeFileSystem`.
#' @export
arrow_bucket <- function(cfg, key, ..., anonymous = FALSE) {
  rlang::check_installed("arrow")
  store <- bucket_key_store(key)
  creds <- store_credentials(cfg, store, anonymous = anonymous)
  path <- sub("^s3://", "", bucket_uri(cfg, key, ..., scheme = "s3"))
  region <- store_region(cfg, store)
  if (anonymous) {
    arrow::s3_bucket(path, endpoint_override = creds$endpoint, region = region,
                     anonymous = TRUE)
  } else {
    arrow::s3_bucket(path, endpoint_override = creds$endpoint, region = region,
                     access_key = creds$key, secret_key = creds$secret)
  }
}

#' Run an expression again if it fails
#'
#' For flaky network calls. Waits `wait` seconds after the first failure,
#' `2 * wait` after the second, and so on.
#'
#' @param expr Expression to evaluate.
#' @param times Maximum number of attempts.
#' @param wait Seconds to wait after the first failure.
#' @return The value of `expr`. If every attempt fails, the last error is
#'   re-raised.
#' @export
#' @examples
#' with_retry(sqrt(4), times = 2, wait = 0)
with_retry <- function(expr, times = 3, wait = 10) {
  expr <- substitute(expr)
  env <- parent.frame()
  for (attempt in seq_len(times)) {
    result <- tryCatch(eval(expr, env), error = identity)
    if (!inherits(result, "error")) return(result)
    if (attempt < times) {
      cli::cli_warn(c(
        "Attempt {attempt} of {times} failed; retrying in {wait * attempt}s.",
        "x" = conditionMessage(result)
      ))
      Sys.sleep(wait * attempt)
    }
  }
  cli::cli_abort("Failed after {times} attempt{?s}.", parent = result)
}

# The bucket path held by a config setting.
bucket_path <- function(cfg, key) {
  path <- if (identical(key, "scratch")) {
    config_get(cfg, "scratch", "bucket")
  } else {
    config_get(cfg, key)
  }
  if (!rlang::is_string(path)) {
    cli::cli_abort("Setting {.field {key}} must be a single string.")
  }
  path
}

# The store each bucket setting belongs to.
bucket_key_store <- function(key) {
  switch(key,
    submissions_bucket = "submissions",
    noaa_forecast_bucket = "noaa",
    scratch = "scratch",
    "main"
  )
}

# The bucket name (first path segment) a store's duckdb secret is scoped to.
store_bucket <- function(cfg, store) {
  key <- switch(store,
    main = "forecasts_bucket",
    submissions = "submissions_bucket",
    noaa = "noaa_forecast_bucket",
    scratch = "scratch"
  )
  path <- tryCatch(bucket_path(cfg, key), error = function(e) NULL)
  if (is.null(path)) return(NULL)
  strsplit(path, "/", fixed = TRUE)[[1]][1]
}

# Open a dataset with duckdbfs, or return NULL if it has no files yet (a new
# challenge, or a query that wrote nothing). Other errors are raised.
open_dataset_if_any <- function(uri, conn = duckdbfs::cached_connection(), ...) {
  tryCatch(
    duckdbfs::open_dataset(uri, conn = conn, ...),
    error = function(e) {
      if (grepl("No files found", conditionMessage(e), fixed = TRUE)) return(NULL)
      stop(e)
    }
  )
}

#' A separate duckdb connection for one unit of work
#'
#' Opens a new disk-backed duckdb connection, which spills to disk instead of
#' running out of memory. It is closed when the calling function exits.
#' `duckdbfs::cached_connection(path)` cannot be used for this: it ignores
#' `path` and returns the shared connection whenever one is open, and closing
#' that would remove every secret registered on it.
#'
#' @param envir Frame whose exit closes the connection.
#' @return A duckdb connection.
#' @export
local_duckdb <- function(envir = parent.frame()) {
  conn <- DBI::dbConnect(duckdb::duckdb(), dbdir = tempfile(fileext = ".duckdb"),
                         config = list(temp_directory = tempfile()))
  DBI::dbExecute(conn, "SET autoinstall_known_extensions=1;")
  DBI::dbExecute(conn, "SET autoload_known_extensions=1;")
  do.call(on.exit, list(quote(DBI::dbDisconnect(conn, shutdown = TRUE)), add = TRUE),
          envir = envir)
  conn
}
