# Changelog

Each release is tagged `vX.Y.Z` and builds the base image
`ghcr.io/eco4cast/challenge-ci:vX.Y.Z`. A challenge upgrades by changing the
version in its trigger workflows (and `ci$docker_image`, if it pins one).

Minor releases only add: new config keys are optional with defaults. A release
that needs challenges to change anything is a major release, and its section
says exactly what to change.

## Unreleased

Minor release; every new key is optional and the defaults keep today's
behaviour.

- Submissions can also be read from contributors' public GitHub repositories,
  alongside the submissions bucket: `submissions$github$registry` turns it on,
  and contributors describe their models in `challenge-model.yaml`. See
  "Submissions from GitHub repositories" in `docs/operations.md`.
- The `submissions` stage publishes what happened to each file, for the bucket
  and GitHub, to `<forecasts_bucket>/submission_results/<model_id>.csv`. This
  adds files to the forecasts bucket.
- `submissions$baselines_destination: forecasts_bucket` makes the baselines
  write straight to the forecasts bucket instead of the submissions bucket
  (default `submissions_bucket`). The baselines workflow now passes the main
  store's key to the job.
- Model metadata can come from `challenge-model.yaml`: `read_registered_models()`
  combines the registration sheet with the files in the registered repositories
  (the file wins per answer), so the `catalog` stage builds model records for
  GitHub models, and `model_metadata_gsheet` may be left out of a GitHub-only
  challenge. A model id belongs to the first repository in the registry that
  lists it.
- Optional registration by GitHub issue: the `register` stage, the
  `_register.yaml` workflow, a trigger (`inst/workflows/register.yaml`) and an
  issue form (`inst/issue_forms/register-forecast-repo.yml`). A bot checks the
  repository, commits its row to the registry file and answers on the issue.
- Scoring no longer fails on a new challenge: with no bundled scores yet it scores
  everything, and with no bundled forecasts yet it finds nothing to score (it
  stopped with "No files found that match the pattern .../scores/bundled-parquet").
- The launch guide's "Set up publishing" step now gives the exact commands and
  settings for creating the `gh-pages` branch and turning on GitHub Pages, with a
  troubleshooting table.
- `public_read: false` keeps the main store private: every read the engine does
  (bundling, scoring, catalog, dashboard, baselines, the targets check) uses the
  key, and targets files are downloaded with it instead of fetched by URL. The
  dashboard workflow now receives the key (used only in this mode). The default
  `true` changes nothing. See "A private bucket" in `docs/operations.md`.
- S3 requests are signed for a region: the config's new optional `region`, or for
  a Backblaze B2 endpoint (`s3.<region>.backblazeb2.com`) the region in the
  endpoint, else `us-east-1` as before. The catalog's participant access code
  names the region when it is not the default.
- `submissions$use_bucket: false` stops reading the bucket (default `true`).
- A file that fails to be recorded no longer counts as recorded for the rest of
  the run.
- New package dependency: httr2, now installed explicitly in the base image.

## v0.1.0

First release, from the generalized neon4cast-ci (branch `generalize-ci`):

- the `challengeci` package, with `run_stage()` as the single entry point
  (`Rscript -e 'challengeci::run_stage()' <stage>`);
- reusable workflows for every stage (`.github/workflows/_*.yaml`) and
  trigger workflows for challenge repos (`inst/workflows/`);
- the dashboard as a template (`inst/dashboard/`) plus each challenge's
  content (`render_dashboard()`);
- `check_challenge_repo()` to check a challenge repository, and a `check`
  workflow that runs it on pull requests;
- `submissions$known_themes_only`, so challenges can share a submissions
  bucket;
- dry runs read targets written by an earlier dry run, and scoring, the
  catalog and the dashboard run for a challenge with no data yet (scoring also
  no longer fails when everything is already scored);
- drivers stages write locally and upload with mc, like every other stage, so
  their dry runs write nothing to S3 and arrow never writes to OSN;
- the base image installs the current arrow release; the arrow 20.0.0 pin is
  dropped, because it cannot compile on R 4.6.
