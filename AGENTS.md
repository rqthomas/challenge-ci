# AGENTS.md

Guidance for anyone (human or AI agent) changing this repository. It runs the
NEON Ecological Forecasting Challenge and is the template for other EFI
challenges. Read the docs it points to before large changes.

## What lives where

| Path | What | Doc |
|---|---|---|
| `challenge_configuration.yaml` | every challenge-specific setting | `docs/configuration.md` |
| `R/` | the `challengeci` package: all shared logic | `docs/developing.md` |
| `inst/scripts/` | thin entry points the workflows run | header of each script |
| `targets/` | challenge-specific data download and cleaning | `docs/launching-a-new-challenge.md` |
| `dashboard/` | Quarto site; reads only `dashboard/data/` | `docs/developing.md` |
| `.github/` | workflows and the composite actions they share | `docs/operations.md` |

## Commands

Run from the repository root.

```sh
Rscript -e 'devtools::test()'                 # unit tests (no network, no secrets)
Rscript -e 'devtools::document()'             # after editing roxygen; commit man/ and NAMESPACE
Rscript -e 'devtools::check()'                # must stay 0 errors, warnings and notes
Rscript -e 'lintr::lint_dir("R")'             # must stay at 0 lints
DRY_RUN=true Rscript inst/scripts/<stage>.R   # run a stage without writing to S3
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
- **The config is read from GitHub `main` by outside tools** (the `neon4cast`
  package). Add keys; never rename or repurpose existing ones.
- **Shared resources:** the model metadata bucket and the Docker image are used
  by other challenges and by participants. Treat changes to them as public.

## Conventions

- Settings come from `cfg`; never hard-code a bucket, endpoint, variable, site
  or horizon. A new setting needs a config key, a row in
  `docs/configuration.md` (a test fails otherwise) and a default in
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
- The NEON API returns 403 from some networks; NEON-based targets scripts may
  only be testable in CI.
- The submissions key can list but not read or delete (see
  `docs/operations.md`).
- Workflow YAML: the `env` context is not available in `strategy.matrix`; pass
  workflow inputs to `run:` steps through `env:`, never inline `${{ }}`.

## Verifying a change

Unit tests are necessary but not sufficient. For anything that changes output,
dry-run the stage against the real (public) buckets and compare with what is
published: for example, a catalog dry run diffed against the catalog
repository, or new targets compared row for row with the published file. Say
in the pull request what you could not test (NEON-dependent scripts, the
workflows themselves).
