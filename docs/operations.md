# Running a challenge

A challenge repository runs each stage with a short trigger workflow, copied
from the engine's `inst/workflows/`, that calls the engine's reusable workflow
at a released version:

```yaml
jobs:
  run:
    uses: eco4cast/challenge-ci/.github/workflows/_scoring.yaml@v0.1.0
    with:
      dry_run: ${{ inputs.dry_run || false }}
    secrets: inherit
```

The reusable workflow reads the challenge's config with `yq` (`_config.yaml`):
the container image (`ci$docker_image`, default the engine's base image of
that release), the large runner (`ci$large_runner`) and the job matrices. Its
jobs check out the challenge repository and run
`Rscript -e 'challengeci::run_stage()' <stage>` (targets jobs run the
challenge's own `targets_script`s).

## Workflows

Times are the schedules in the engine's trigger templates (UTC); each
challenge sets its own. "Large" means the self-hosted runner named by
`ci$large_runner`.

| Trigger (reusable workflow) | Schedule | Runner | Runs | Healthcheck |
|---|---|---|---|---|
| `submissions.yaml` (`_submissions.yaml`) | every 2 h | GitHub | `run_stage() submissions` | `submissions` |
| `bundling.yaml` (`_bundling.yaml`) | every 6 h | GitHub | `run_stage() bundle forecasts`, `... summaries` | `bundling` |
| `scoring.yaml` (`_scoring.yaml`) | 10:00 | large | `run_stage() score [since]` | `scoring` |
| `targets.yaml` (`_targets.yaml`) | 07:00 | GitHub, or large for groups with `targets_large_runner` | each group's `targets_script` | `targets-<group>`, then `targets` when all succeed |
| `baselines.yaml` (`_baselines.yaml`) | 20:00 daily; 01:00 Sunday weekly | GitHub | `run_stage() baselines <schedule> <group>` per group | `baselines-daily` / `baselines-weekly` when all succeed |
| `drivers_stage1_2.yaml` (`_drivers_stage1_2.yaml`) | 05:00 | GitHub | `run_stage() drivers-stage1-2` | `drivers-stage1-2` |
| `drivers_stage3.yaml` (`_drivers_stage3.yaml`) | 23:00 | large | `run_stage() drivers-stage3 [rebuild]` | `drivers-stage3` |
| `catalog.yaml` (`_catalog.yaml`) | 23:00 | GitHub | `run_stage() catalog`, then commits to `catalog_config$catalog_repo` | `catalog` |
| `dashboard.yaml` (`_dashboard.yaml`) | 08:00 | GitHub | `run_stage() dashboard`, publishes to the challenge's `gh-pages` | `dashboard` |
| `docker.yaml` (`_docker.yaml`) | Sunday 00:00 | GitHub | builds `challenge/Dockerfile` as `ci$docker_image` | `docker` |
| `check.yaml` (`_check.yaml`) | pull requests and pushes | GitHub | `run_stage() check` | — |

The engine repository runs its own: `package-tests.yaml` (tests and R CMD
check on pull requests), `docker.yaml` (the base image
`ghcr.io/<owner>/challenge-ci:main`, on changes to `main`),
`template-check.yaml` (every stage of `challenge-template` as a dry run with
the changed engine, on pull requests and nightly; repository variable
`TEMPLATE_REPO` and, while the template is private, secret `TEMPLATE_TOKEN`)
and `release.yaml` (see [developing.md](developing.md#releasing)).

Each trigger has a `concurrency` group, so a run waits for the previous one
instead of overlapping it. Each job has a `timeout-minutes` about three times
its longest recent run.

### Healthchecks

The last step of a job pings the URL under its name in `ci$healthchecks`
(through `ping_healthcheck()`), so a ping means the job succeeded. A job with
no URL in the config is simply not monitored; add one to start monitoring it.

## Upgrading the engine

Change the version after `@` in every trigger workflow (and the `FROM` tag in
`challenge/Dockerfile`, if the challenge has one) to the new release, after
reading its `CHANGELOG.md` section. Dependabot can open these pull requests:
add `.github/dependabot.yml` with the `github-actions` ecosystem.

## Secrets

Set these as GitHub repository secrets of the challenge repository. The
config names the environment variables the code reads (`credentials`); the
reusable workflows map secrets onto them.

| Secret | Read as | Used by | For |
|---|---|---|---|
| `OSN_KEY`, `OSN_SECRET` | same | most workflows | writing to the main store (`endpoint`) |
| `AWS_ACCESS_KEY_SUBMISSIONS`, `AWS_SECRET_ACCESS_KEY_SUBMISSIONS` | same | submissions, baselines | the submissions bucket: listing and moving files, uploading baseline forecasts |
| `EFI_NRP_KEY`, `EFI_NRP_SECRET` | same | scoring, targets | the scratch store (`scratch`) |
| `NEON_TOKEN` | same | targets | NEON API downloads (NEON-based challenges) |
| `CATALOG_TOKEN` | `EXTERNAL_GH_PAT` | catalog | pushing to the catalog repository |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | — | challenge-image | pushing the challenge image to Docker Hub |
| `PAT` | build secret `github_pat` | challenge-image | GitHub installs during the build, without rate limits (optional) |

For local runs, the same names go in `.Renviron` at the challenge repository's
root, which R reads at startup. `.Renviron` is never committed.

## Common tasks

- **Rerun a stage:** open the workflow in the Actions tab and choose *Run
  workflow*. Concurrency groups queue it behind any run in progress.
- **Try a change without writing data:** run the workflow manually with *dry
  run* ticked. It runs on the real runner, image and secrets and reads the
  real buckets, but sets `DRY_RUN=true`: nothing is written to S3, the catalog
  is not pushed, the dashboard is not published and no healthcheck is pinged.
  Targets, baselines, submissions, catalog and dashboard runs keep their output
  as a downloadable artifact for 7 days (bundling, scoring and drivers do not,
  because their output is large). A dry run of *challenge-image* builds the
  image without pushing it. Locally, run the stage with `DRY_RUN=true`
  (see [developing.md](developing.md)); writes go to `DRY_RUN_DIR`.
- **Rebuild stage 3 drivers from scratch:** run *drivers-stage3* manually with
  *rebuild* ticked. It can take many hours, so its timeout is 24 h.
- **Run baselines by hand:** run *baseline-forecasts* manually and choose daily
  or weekly.
- **Roll back the image:** each build of a challenge image is also tagged
  with its date. Set `ci$docker_image` to e.g.
  `ghcr.io/eco4cast/neon4cast-challenge:2026-11-18` to pin every workflow to
  that build, and back to `:latest` to follow new builds. The image name must
  be the challenge's own: the workflow pushes to it.
- **Upgrade a package in the image:** engine packages are pinned in the
  engine's `Dockerfile` (they change with engine releases); a challenge's own
  packages are in its `challenge/Dockerfile`.

## Scoring older forecasts and rescoring

Each scoring run scores forecast rows from the last six months that have an
observation but no score yet. Rows already scored are never scored again.

- **Score older forecasts** (after a long outage, or when observations arrive
  late): run *scoring* manually with *since* set to a date, e.g. `2025-01-01`.
  Locally: `Rscript -e 'challengeci::run_stage()' score 2025-01-01`. A long window takes
  longer and uses more scratch space.
- **Rescore a model or variable** (after its observations were corrected):
  its existing scores must go first, because scored rows are skipped. Copy the
  model's folder under `<scores_bucket>/bundled-parquet/` aside (e.g. with
  `mc cp --recursive`), delete it, then run *scoring* with *since* early enough
  to cover the model's forecasts.

## Recovering from failed bundling

Bundling moves each processed file through three folders of the forecasts
bucket (summaries use `summaries/`, `bundled-summaries/`, `archive-summaries/`):

```
parquet/<model path>/...   new, not yet bundled
bundled-parquet/<model path>/data_0.parquet   one file per model
archive-parquet/<model path>/...   bundled, kept as the raw record
```

- **A run fails:** usually nothing to do. A model that fails keeps its files
  in `parquet/`, the others still finish, and the next run retries it. If a
  run uploaded a bundle but failed before archiving the files, the next run
  recognises the rows (same `reference_datetime` and `pub_datetime`) and does
  not add them twice. The log names each model that failed and why.
- **A bundle is damaged:** rebuild it from the archive. Copy the bundle aside,
  move the model's files from `archive-parquet/<model path>/` back to
  `parquet/<model path>/`, delete `bundled-parquet/<model path>/`, and run
  *bundling*. It rebuilds the bundle from every archived file.
- **Check before changing anything:** `DRY_RUN=true VERBOSE=true Rscript -e
  'challengeci::run_stage()' bundle forecasts` reads the real buckets, writes
  the bundles locally, and counts the rows in every bundle before and after.

## The submissions bucket workaround

Since 2026-09-08 the NRP submissions key can only list the submissions bucket:
reading and deleting with it fail with "Insufficient permissions". The
bucket's own policy lets anyone read and delete, so processing lists the
bucket with the key and reads and deletes anonymously. Deleting may still
fail, so processing also keeps its own record of every submission handled
(`processed_submissions`, on the main store) and skips those files. The two
minio client aliases are at the top of the engine's `R/submissions.R`; once
NRP restores the key's permissions, drop the anonymous one there.
