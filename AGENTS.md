# AGENTS.md

Guidance for anyone (human or AI agent) changing `challenge-ci`, the engine
shared by the EFI forecasting challenges. Each challenge has its own repository
(named `<project_id>-challenge`) holding its config, targets scripts and
dashboard text; this repository holds no challenge's files. Read the docs it
points to before large changes.

## What lives where

| Path | What | Doc |
|---|---|---|
| `R/` | the `challengeci` package: all shared logic; `run_stage()` is the entry point | `docs/developing.md` |
| `inst/dashboard/` | the dashboard template (pages, JS modules, styles); challenges add their text | `docs/dashboard-data.md`, `docs/developing.md` |
| `inst/workflows/` | trigger workflows challenge repos copy | `docs/operations.md` |
| `.github/` | reusable workflows (`_*.yaml`), actions, image and release workflows | `docs/operations.md` |
| `tests/testthat/fixtures/` | example configs: a minimal one, and `tests/testthat/fixtures/full_config.yaml` (a complete real challenge) | `docs/configuration.md` |

A challenge repository checks itself with `check_challenge_repo()`: its config
is valid and every file the config names exists.

## Commands

Run from the repository root.

```sh
Rscript -e 'devtools::test()'                 # unit tests (no network, no secrets)
Rscript -e 'devtools::document()'             # after editing roxygen; commit man/ and NAMESPACE
Rscript -e 'devtools::check()'                # must stay 0 errors, warnings and notes
Rscript -e 'lintr::lint_dir("R")'             # must stay at 0 lints
DRY_RUN=true Rscript -e 'challengeci::run_stage()' <stage>   # from a challenge repo: no S3 writes
```

## Rules that protect production

- **Never write to S3 outside a dry run unless asked.** Every write goes through
  `upload_file()`, `upload_dir()`, `move_remote()`, `remove_remote()` or
  `output_uri()`, so `DRY_RUN=true` catches it. Don't add a write that bypasses
  them.
- **Healthchecks and other side effects must skip dry runs** (`ping_healthcheck()`
  does).
- **Secrets:** never read or print `.Renviron`; never put keys in the config,
  workflow files or Docker build-args. The config holds only the *names* of the
  environment variables.
- **Challenge configs are read from GitHub by outside tools** (for NEON, the
  `neon4cast` package). Add keys; never rename or repurpose existing ones.
- **Shared resources:** the model metadata bucket and the images are used by
  other challenges and by participants. Treat changes to them as public.
- **Releases are public contracts:** challenges pin a version. Anything that
  makes them change files is a major release with a `CHANGELOG.md` note.

## Conventions

- Settings come from `cfg`; never hard-code a bucket, endpoint, variable, site
  or horizon. A new setting needs a config key, a row in
  `docs/configuration.md` (a test checks the keys of
  `tests/testthat/fixtures/full_config.yaml`) and a default in
  `config_defaults()` when a sensible one exists.
- Tidyverse style, native pipe, `pkg::fun()` inside `R/`, explicit `by =` in
  joins.
- Push filters and aggregation into duckdb before `dplyr::collect()`.
- Per-item failures (a model, a group, a site) are logged, the loop continues,
  and the run fails at the end.

## Known traps

- `duckdbfs::open_dataset()` on a single remote file: pass `recursive = FALSE`,
  or it appends `/**`.
- duckdb (>= 2.0) and arrow uploads fail on OSN: write locally, then upload
  with mc.
- `duckdbfs::cached_connection(path)` ignores `path` once a connection exists;
  use `local_duckdb()` for a separate one.
- Inside dbplyr filters, compute R values first and inject them with `!!`.
- Object storage goes through paws.storage (`remote_connect()`, `remote_files()`,
  `upload_file()`, ...), not the MinIO client, which is no longer supported. Remote
  paths are `<alias>/<bucket>/<key>`; call `remote_connect()` for the alias first.
- The submissions key can list but not read or delete (see
  `docs/operations.md`).
- Workflow YAML: the `env` context is not available in `strategy.matrix`; pass
  workflow inputs to `run:` steps through `env:`, never inline `${{ }}`.
- In a reusable workflow, `./` paths point at the calling challenge's checkout:
  refer to engine actions and workflows as `eco4cast/challenge-ci/...@main`
  (the release workflow rewrites them).
- The Quarto visual editor rewrites inline R inside link URLs; keep pages in
  source mode.
- Repositories are read with plain git (`R/git_repos.R`). Never use `git ls-tree -l`
  in a partial clone (it fetches every blob), and clone `https://host/owner/name.git`
  (GitLab redirects every request without `.git`). Tests use local bare repos with
  `options(challengeci.git_protocols = c("https", "file"))`.
- The processed record and the unit record are written in batches by `flush_state` in `R/submissions.R`;
  bucket deletes must come after a successful record write, and a failed source still
  flushes what it did.
- `dplyr::bind_rows(named_list, df)` treats the list as columns; use
  `bind_rows(c(unname(list), list(df)))`.

## Verifying a change

Unit tests are necessary but not sufficient. For anything that changes output,
dry-run the stage against the real (public) buckets and compare with what is
published: for example, a catalog dry run diffed against the catalog
repository, or new targets compared row for row with the published file. Say
in the pull request what you could not test (NEON-dependent scripts, the
workflows themselves).
