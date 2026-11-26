# An in-memory stand-in for a paws S3 client: the methods the engine calls, with
# objects kept in an environment. `page_size` makes listings page, so pagination is
# exercised; `calls` records every call by name. As in S3, a single-request object's
# ETag is the MD5 of its body.
fake_s3 <- function(page_size = 1000) {
  store <- new.env()          # key -> list(body = raw, etag, type)
  uploads <- new.env()        # upload id -> list(key, parts)
  calls <- character()
  hooks <- list()             # name -> function(args) run before the call (to inject errors)
  record <- function(name, args) {
    calls <<- c(calls, name)
    if (!is.null(hooks[[name]])) hooks[[name]](args)
  }
  put <- function(Bucket, Key, Body, ContentType = NULL) {
    body <- if (is.raw(Body)) Body else readBin(Body, "raw", file.size(Body))
    tmp <- tempfile()
    writeBin(body, tmp)
    on.exit(unlink(tmp))
    assign(paste(Bucket, Key, sep = "/"),
           list(body = body, etag = unname(tools::md5sum(tmp)), type = ContentType),
           envir = store)
  }
  keys_in <- function(Bucket, Prefix = "") {
    all <- ls(store, all.names = TRUE)
    prefix <- paste0(Bucket, "/", Prefix)
    sort(sub(paste0("^", Bucket, "/"), "", all[startsWith(all, prefix)]))
  }
  http_error <- function(status, message) {
    structure(class = c("paws_error", paste0("http_", status), "http_error", "error", "condition"),
              list(message = message, call = NULL))
  }
  client <- list(
    list_objects_v2 = function(Bucket, Prefix = "", ContinuationToken = NULL) {
      record("list_objects_v2", list(Bucket = Bucket, Prefix = Prefix))
      keys <- keys_in(Bucket, Prefix)
      start <- if (is.null(ContinuationToken)) 1 else as.integer(ContinuationToken)
      index <- seq_along(keys)
      page <- keys[index >= start & index < start + page_size]
      more <- start + page_size <= length(keys)
      list(
        Contents = lapply(page, function(k) {
          o <- get(paste(Bucket, k, sep = "/"), envir = store)
          list(Key = k, Size = length(o$body), ETag = paste0("\"", o$etag, "\""))
        }),
        IsTruncated = more,
        NextContinuationToken = if (more) as.character(start + page_size)
      )
    },
    head_object = function(Bucket, Key) {
      record("head_object", list(Bucket = Bucket, Key = Key))
      if (!exists(paste(Bucket, Key, sep = "/"), envir = store)) stop(http_error(404, "Not Found"))
      list(ContentLength = 1)
    },
    get_object = function(Bucket, Key) {
      record("get_object", list(Bucket = Bucket, Key = Key))
      id <- paste(Bucket, Key, sep = "/")
      if (!exists(id, envir = store)) stop(http_error(404, "NoSuchKey"))
      list(Body = get(id, envir = store)$body)
    },
    put_object = function(Bucket, Key, Body, ContentType = NULL) {
      record("put_object", list(Bucket = Bucket, Key = Key, ContentType = ContentType))
      put(Bucket, Key, Body, ContentType)
      list(ETag = "x")
    },
    create_multipart_upload = function(Bucket, Key, ContentType = NULL) {
      record("create_multipart_upload", list(Bucket = Bucket, Key = Key))
      id <- paste0("upload-", length(ls(uploads)) + 1)
      assign(id, list(Bucket = Bucket, Key = Key, type = ContentType, parts = list()), envir = uploads)
      list(UploadId = id)
    },
    upload_part = function(Bucket, Key, UploadId, PartNumber, Body) {
      record("upload_part", list(PartNumber = PartNumber, size = length(Body)))
      u <- get(UploadId, envir = uploads)
      u$parts[[PartNumber]] <- Body
      assign(UploadId, u, envir = uploads)
      list(ETag = paste0("etag-", PartNumber))
    },
    complete_multipart_upload = function(Bucket, Key, UploadId, MultipartUpload) {
      record("complete_multipart_upload", list(parts = length(MultipartUpload$Parts)))
      u <- get(UploadId, envir = uploads)
      # As on S3: every part but the last must be at least 5 MiB.
      sizes <- vapply(u$parts, length, numeric(1))
      if (any(head(sizes, -1) < 5 * 1024^2)) stop(http_error(400, "EntityTooSmall"))
      put(Bucket, Key, do.call(c, u$parts), u$type)
      # A multipart object's ETag is not an MD5 of its body.
      id <- paste(Bucket, Key, sep = "/")
      o <- get(id, envir = store)
      o$etag <- paste0("multipart-", length(u$parts))
      assign(id, o, envir = store)
      rm(list = UploadId, envir = uploads)
      list()
    },
    abort_multipart_upload = function(Bucket, Key, UploadId) {
      record("abort_multipart_upload", list(Key = Key))
      if (exists(UploadId, envir = uploads)) rm(list = UploadId, envir = uploads)
      list()
    },
    copy_object = function(Bucket, Key, CopySource) {
      record("copy_object", list(Key = Key, CopySource = CopySource))
      source <- get(CopySource, envir = store)
      assign(paste(Bucket, Key, sep = "/"), source, envir = store)
      list()
    },
    delete_object = function(Bucket, Key) {
      record("delete_object", list(Key = Key))
      id <- paste(Bucket, Key, sep = "/")
      if (exists(id, envir = store)) rm(list = id, envir = store)
      list()
    },
    delete_objects = function(Bucket, Delete) {
      record("delete_objects", list(n = length(Delete$Objects), quiet = Delete$Quiet))
      for (o in Delete$Objects) {
        id <- paste(Bucket, o$Key, sep = "/")
        if (exists(id, envir = store)) rm(list = id, envir = store)
      }
      list(Errors = list())
    }
  )
  structure(client, class = "fake_s3", store = store, calls = function() calls,
            hook = function(name, fn) hooks[[name]] <<- fn, put = put, keys = keys_in)
}

# An error as paws raises it: the classes carry the HTTP status, and the fields say
# what the store answered.
paws_http_error <- function(status, message, code = NULL) {
  structure(class = c("paws_error", paste0("http_", status), "http_error", "error", "condition"),
            list(message = message, call = NULL, status_code = status,
                 error_response = if (!is.null(code)) list(Code = code)))
}
paws_503 <- function() {
  paws_http_error(503, "ServiceUnavailable (HTTP 503). Service unavailable, please try again later.",
                  "ServiceUnavailable")
}

# Register a fake client under an alias for the rest of the test. The pauses
# between retries are 0 s, so a test that makes the fake fail does not wait.
local_fake_s3 <- function(alias = "main", env = parent.frame(), ...) {
  withr::local_options(challengeci.s3_retry_wait = 0, challengeci.stage_retry_wait = 0,
                       .local_envir = env)
  fake <- fake_s3(...)
  remote_clients[[alias]] <- fake
  withr::defer(rm(list = alias, envir = remote_clients), envir = env)
  fake
}
fake_calls <- function(fake) attr(fake, "calls")()
fake_put <- function(fake, bucket, key, text = "x") attr(fake, "put")(bucket, key, charToRaw(text))
fake_keys <- function(fake, bucket, prefix = "") attr(fake, "keys")(bucket, prefix)
fake_hook <- function(fake, name, fn) attr(fake, "hook")(name, fn)
