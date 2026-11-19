# Developing the engine

`challenge-ci` is the engine shared by the forecasting challenges. It holds no
challenge's files: each challenge has its own repository
(`<project_id>-challenge`) with its config, targets scripts and dashboard text,
which uses a released version of this engine.

```
DESCRIPTION, NAMESPACE   the challengeci package (NAMESPACE is generated, do not edit)
R/                       package functions, documented with roxygen comments
man/                     help pages (generated, do not edit)
tests/testthat/          unit tests; fixtures/ holds example configs
inst/dashboard/          the dashboard template (Quarto pages, helpers, default text)
inst/workflows/          trigger workflows that challenge repos copy
inst/extdata/            data shipped with the package (catalog column descriptions)
.github/workflows/_*.yaml   reusable workflows, one per stage
.github/workflows/       docker.yaml (base image), release.yaml, package-tests.yaml
.github/actions/         composite actions the reusable workflows share
Dockerfile               the base image: R, dependencies and the package
docs/                    configuration, operations, development and launch guides
CHANGELOG.md             what each release changes, and what challenges must do
```

## How a stage runs

A challenge repository's trigger workflow (copied from `inst/workflows/`) holds
only the schedule and calls the engine's reusable workflow at a released
version, e.g. `eco4cast/challenge-ci/.github/workflows/_scoring.yaml@v0.1.0`.
That workflow reads the challenge's config (`_config.yaml`), starts the
challenge's image (`ci$docker_image`, or the engine's base image of that
release), checks out the challenge repository and runs one command:

```sh
Rscript -e 'challengeci::run_stage()' <stage> [arguments]
```

`?run_stage` lists the stages: `submissions`, `register`, `bundle`, `score`, `baselines`,
`drivers-stage1-2`, `drivers-stage3`, `catalog`, `dashboard` and `check`.
Targets are the exception: the challenge's own `targets_script`s run directly
and end with `format_targets() |> check_targets() |> write_targets()`.

## Working on the engine with a challenge

Clone the engine and a challenge repository side by side, then run stages from
the challenge's root against your copy of the engine:

```sh
cd neon4cast-challenge
Rscript -e 'pkgload::load_all("../challenge-ci"); run_stage("check")'
DRY_RUN=true Rscript -e 'pkgload::load_all("../challenge-ci"); run_stage("catalog")'
Rscript -e 'pkgload::load_all("../challenge-ci"); render_dashboard(read_config(), "site")'
```

or install your copy (`R CMD INSTALL ../challenge-ci`) and use the same
commands as the workflows. The challenge's targets scripts load the installed
package with `library(challengeci)`. Credentials come from the environment:
R reads `.Renviron` in the working directory at startup, and `.Renviron` is
never committed.

## The dashboard template

`render_dashboard()` copies `inst/dashboard/` to a temporary folder, lays the
challenge's content folder (`dashboard$content_dir`, default
`challenge/dashboard`) over it, stages the data and renders with Quarto. Pages
pull challenge-specific sections from `_content/` with
`{{< include _content/<file>.qmd >}}`; the template's `_content/` files are
generic defaults that a challenge replaces by shipping a file of the same name.
Pages load `R/setup.R`, which provides `cfg`, `settings`, `links` and
`data_file()`. Keep the editor in source mode (`editor: source`): the visual
editor rewrites inline R inside link URLs and breaks the links.

## The edit, document, test loop

From the engine's root, in R:

```r
devtools::load_all()   # reload after editing R/
devtools::document()   # after changing roxygen comments (#') or adding a function
devtools::test()       # run tests/testthat
devtools::check()      # full R CMD check before opening a PR
lintr::lint_dir("R")   # style (rules in .lintr)
```

Commit the regenerated `NAMESPACE` and `man/` files with your change. The
`package-tests` workflow runs the tests and `R CMD check` in the base image on
every pull request.

## Releasing

Releases are made by the `release` workflow, run by hand with a version, e.g.
`0.2.0` or `0.2.0-rc.1`. It stamps the version into `DESCRIPTION`, rewrites
every `eco4cast/challenge-ci/...@main` reference in the reusable workflows,
actions and `inst/workflows/` to `<this repository>/...@v<version>`, tags that
commit, builds the base image `ghcr.io/<owner>/challenge-ci:v<version>` and
creates the GitHub release from the `CHANGELOG.md` section. `main` itself keeps
the `@main` references. Because the owner comes from the repository, the same
workflow releases from a staging copy under another account.

The workflow needs the repository secret `RELEASE_TOKEN`: the tagged commit
changes workflow files, which GitHub never lets the built-in `GITHUB_TOKEN`
push. Use a fine-grained token limited to this repository with **Contents** and
**Workflows** set to read and write (in `eco4cast`, an organisation-owned token
or GitHub App token, so releases don't depend on one person's account).

Before releasing, add a `## vX.Y.Z` section to `CHANGELOG.md`. Minor releases
only add (new config keys are optional with defaults); anything that requires
challenges to change is a major release, and its section says what to change.

## Conventions

- **The config is the source of truth.** Never write a bucket, endpoint,
  project id, variable, horizon or site list into code. Read it from `cfg`. If
  a setting does not exist yet, add a new key to the config, document it in
  [configuration.md](configuration.md), and give it a default in
  `config_defaults()` when a sensible one exists.
- **Nothing challenge-specific in the engine.** Text, images, sites and
  scripts belong to challenge repositories; the engine reaches them only
  through the config.
- **Functions take `cfg` and data as arguments.** No globals.
- **Tidyverse style:** native pipe `|>`, snake_case, `pkg::fun()` calls inside
  `R/` (no `library()`), and explicit `by =` in joins. Use `purrr::map()`/`walk()`
  rather than loops that grow objects.
- **Fail loudly.** Use `cli::cli_abort()` with a message that says what to fix.
  When one item fails in a loop over many (submissions, groups, models),
  record the failure, carry on, and exit non-zero at the end.
- **Do as much as possible in duckdb.** Filter and aggregate before `collect()`.
- **Writes respect dry runs.** Send every change to S3 through
  `upload_file()`, `upload_dir()`, `move_remote()` or `remove_remote()`, or
  write to a path from `output_uri()`. Then `DRY_RUN=true` sends it to a
  local folder or only logs it.
- **Upload with mc.** duckdb (>= 2.0) cannot finish multipart uploads to OSN,
  and arrow's uploads fail there too. Write locally, then `upload_file()` or
  `upload_dir()`.
- **Pass `recursive = FALSE` when giving `duckdbfs::open_dataset()` a file.**
  Given a single remote path, it otherwise treats it as a folder and adds
  `/**`.
- **Reusable workflows refer to the engine by full name**
  (`eco4cast/challenge-ci/...@main`), never `./`: inside a called workflow,
  `./` is the challenge's checkout. A test enforces this.
- **Comments explain why.** Every exported function has roxygen docs with
  `@param` and `@return`.

## Testing without touching production

- `DRY_RUN=true` sends all package writes to `DRY_RUN_DIR` (default: a
  temporary folder) and only logs moves and deletes. Reads still use the real
  buckets, anonymously if no credentials are set, so most stages can be
  dry-run with no secrets at all. Only reading the submissions bucket needs
  its key, because only that key can list it.
- In a dry run, stages that read targets read a group's file from
  `DRY_RUN_DIR` when an earlier dry run wrote it there (`targets_files()`),
  so a pipeline can be dry-run before any targets are published.
- Stages must cope with a challenge that has no data yet: open bundled
  datasets with `open_dataset_if_any()`, which returns `NULL` instead of
  failing when there are no files. The template repository is the test case.
- `CHALLENGE_CONFIG=path/to/config.yaml` points everything at a different
  config.
- Every trigger workflow has a *dry run* option for manual runs on GitHub.
