# Changelog

Each release is tagged `vX.Y.Z` and builds the base image
`ghcr.io/eco4cast/challenge-ci:vX.Y.Z`. A challenge upgrades by changing the
version in its trigger workflows (and `ci$docker_image`, if it pins one).

Minor releases only add: new config keys are optional with defaults. A release
that needs challenges to change anything is a major release, and its section
says exactly what to change.

## Unreleased

**Breaking for the main store's key:** the secrets and environment variables that
held it are renamed from `OSN_KEY` and `OSN_SECRET` to the store-neutral
`S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`. To upgrade a challenge, (1) add
repository secrets with the new names (the same values), (2) rename the same
variables in your `.Renviron`, and (3) if the config has its own `credentials:`
block naming the old variables, change it to the new names or delete it (the new
names are the defaults). The workflows no longer pass `OSN_KEY` or `OSN_SECRET`,
so a challenge that keeps the old secrets stops being able to reach the store.
The other stores' names (`EFI_NRP_*`, `AWS_*_SUBMISSIONS`) are unchanged.

This release is therefore a major one. Apart from the rename, every new key is
optional and the defaults keep today's behaviour.

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
- The challenge's baseline models are registered automatically (described from
  their `method`, or by optional `long_name`, `description` and `model_type` in
  the baseline entry) unless the model id is registered already. They now appear in
  the catalog, the model metadata and the dashboard's plot of model types, which
  was empty for a challenge with no registrations. `read_registered_models()`
  gains a `baseline` column. The plot says so when no model has described its
  approach yet.
- The dashboard's instructions follow the submission method: with GitHub
  submissions the overview step, the "Submitting a forecast" heading and the
  processing text say so, and `dashboard$example_submission_repo` links a working
  example.
- The catalog no longer fails for a kind with nothing bundled yet (the `scores`
  part stopped with "Path does not exist .../scores/bundled-parquet/" before the
  first scoring run): it writes an empty collection, and the columns appear once
  data exist.
- **The MinIO client is gone.** `mc` and `minioclient` are unsupported (the MinIO
  download answers HTTP 410), so every listing, download, upload, move and delete of
  S3 objects now goes through the [paws.storage](https://github.com/paws-r/paws) R
  package: nothing is downloaded at run time and no program is installed. New
  dependency: paws.storage (>= 0.11.0); removed: minioclient and openssl. Nothing to
  change in a challenge's config. Large files upload in parts and a repeated folder
  upload sends only what changed. Removed or renamed (a challenge's scripts must
  follow):
  - `ensure_mc()` is removed, and so is the `install-mc` action (the workflows no
    longer install anything). **Targets scripts: delete the line that calls
    `minioclient::install_mc()` or `install_mc()`.**
  - `mc_connect()` is now `remote_connect()`; `mc_to_s3()` is now `remote_to_s3()`;
    `bucket_uri(scheme = "mc")` is now `bucket_uri(scheme = "remote")`. A "remote
    path" is `<alias>/<bucket>/<key>` as before.
  - New: `remote_exists()` and `remote_download()`; `remote_files()` also returns
    each file's `etag`.
- `update-engine` workflow (`_update-engine.yaml`, trigger in
  `inst/workflows/update-engine.yaml`): moves every workflow of a challenge to a
  chosen engine release, or the latest, and opens a pull request. Needs the
  secret `WORKFLOW_TOKEN`; see "Upgrading the engine" in `docs/operations.md`.
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
- **New dashboard.** The site is rebuilt as a participant-first dashboard:
  Overview, Targets, Leaderboard, Forecasts (an explorer), Data, Participate and
  a page per model. It works for private buckets: R reads the buckets with the
  key and writes small public JSON files (the contract in
  `docs/dashboard-data.md`); the pages, plain JavaScript modules with no build
  step, read only those. Leaderboards now show skill against the climatology
  baseline (summed CRPS on the forecasts both made) as well as CRPS, over 7, 30
  and 90 days (90, 180 and 365 for weekly variables). Participants can read how
  to access each dataset (with a key when the bucket is private) and check what
  happened to each file they submitted ("Check my submissions", from the
  published submission results).
  - What a challenge has to change: nothing is required. Content partials
    (`_content/*.qmd`, `targets/<group>.md`, `img/banner.jpg`) still work.
    `dashboard$extra_pages` now takes `{href, title}` (the Bootstrap `icon` is
    ignored). The pages no longer use Bootstrap, so a challenge page that relied
    on its components needs its own styles (`challenge.css` in the content
    folder, loaded after the template's).
  - The Targets page draws each variable's observations at the focal sites in
    the browser, with the same chart as the forecast explorer (from the new
    `targets/<variable>.json` files), and its map zooms to fit the sites.
  - New optional keys: `dashboard$tagline`, `key_request_url`, `min_forecasts`,
    `skill_baseline`, `publish_results`.
  - The old Performance and Catalog pages are gone (replaced by Leaderboard,
    Forecasts and Data); the staged `forecasts.parquet`, `analysis.parquet`,
    `leaderboard.parquet`, `stats.json` and `model_types.csv` are no longer
    written. `render_dashboard()` takes `data_dir` to build from an
    already-staged folder.

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
