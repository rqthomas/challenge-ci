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
| `update-engine.yaml` (`_update-engine.yaml`) | by hand (optional weekly) | GitHub | opens a pull request moving the workflows to a new engine release | |
| `register.yaml` (`_register.yaml`) | when a registration issue is opened or edited | GitHub | `run_stage() register` | |
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

A challenge pins the engine by the version after `@` in each of its trigger
workflows (`.../_scoring.yaml@v0.4.0`), and optionally in the `FROM` tag of
`challenge/Dockerfile` and in `ci.docker_image`. Read the release's
`CHANGELOG.md` section first: a minor release only adds, a major one says what
to change.

**With the `update-engine` workflow (recommended).** Copy
`inst/workflows/update-engine.yaml` to `.github/workflows/` of the challenge
repository. Run it from the Actions tab (*update-engine → Run workflow*) with a
version such as `0.4.0` (no leading `v`), or leave the version empty for the latest
stable release (tick *include prereleases* to take a release candidate). It
checks that the release exists, rewrites **every** engine reference in
`.github/workflows` and `.github/actions` (this workflow's own included) and the
engine image in `challenge/Dockerfile` and `challenge_configuration.yaml`, and
opens a pull request named `update-engine-v<version>`. The challenge's `check`
workflow runs on it; merge it to switch, then run the workflows you want to
confirm. If you are already on that version it says so and opens nothing.
Uncomment the `schedule:` in the trigger to check for a new stable release every
Monday.

It needs a repository secret, **`WORKFLOW_TOKEN`**, because GitHub does not let
the built-in token change files under `.github/workflows` or start the check on
a pull request it opened. Create it once:

1. On github.com open **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. *Resource owner*: the account or organization that owns the challenge
   repository. *Repository access*: **Only select repositories**, and choose the
   challenge repository. Set an expiry you can live with (and renew it then).
3. *Repository permissions*: **Contents**, **Pull requests** and **Workflows**,
   each *Read and write*. Generate the token and copy it.
4. Store it: `gh secret set WORKFLOW_TOKEN -R <owner>/<repo>` and paste it when
   asked (or Settings → Secrets and variables → Actions → New repository secret).

(An organization may need an owner to approve fine-grained tokens first.)

**By hand.** From the root of the challenge repository, with the new tag in `NEW`:

```sh
NEW=v0.4.0
grep -rl 'challenge-ci/.github' .github | xargs sed -i.bak -E "s#(challenge-ci/\.github/(workflows|actions)/[A-Za-z0-9_./-]+)@[A-Za-z0-9_.-]+#\1@$NEW#g"
find . -name '*.bak' -delete
```

Dependabot can also open these pull requests (add `.github/dependabot.yml` with the
`github-actions` ecosystem). That route has not been tried here; check that it
proposes release candidates if you pin one, and note that it leaves the Dockerfile
and `ci.docker_image` alone.

## Secrets

Set these as GitHub repository secrets of the challenge repository (how to create
each one is in [launching-a-new-challenge.md](launching-a-new-challenge.md#5-add-the-secrets-and-tokens)).
The config names the environment variables the code reads (`credentials`); the
reusable workflows map secrets onto them.

| Secret | Read as | Used by | For |
|---|---|---|---|
| `OSN_KEY`, `OSN_SECRET` | same | most workflows | the main store (`endpoint`): reading and writing |
| `EFI_NRP_KEY`, `EFI_NRP_SECRET` | same | scoring, targets | the scratch store (`scratch`), unless `credentials.scratch` points at the main key |
| `AWS_ACCESS_KEY_SUBMISSIONS`, `AWS_SECRET_ACCESS_KEY_SUBMISSIONS` | same | submissions, baselines | the submissions bucket (only when it is used): listing and moving files, uploading baseline forecasts |
| `NEON_TOKEN` | same | targets | NEON API downloads (NEON-based challenges) |
| `CATALOG_TOKEN` | `EXTERNAL_GH_PAT` | catalog | pushing to the catalog repository |
| `WORKFLOW_TOKEN` | — | update-engine | opening the pull request that changes the workflow files (see Upgrading the engine) |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | — | challenge-image | pushing the challenge image to Docker Hub (not needed for `ghcr.io`) |
| `PAT` | build secret `github_pat` | challenge-image | GitHub installs during the build, without rate limits (optional) |

In the engine repository itself: `RELEASE_TOKEN` (the `release` workflow) and
`TEMPLATE_TOKEN` (`template-check`, while the template is private).

The built-in `GITHUB_TOKEN` covers the dashboard's push to `gh-pages` and the
registration workflow; the trigger workflows request the permissions they need.
For local runs, the same names go in `.Renviron` at the challenge repository's
root, which R reads at startup. `.Renviron` is never committed.

## The MinIO client

Uploads and most listings go through the MinIO client, `mc`. MinIO has withdrawn
the download that `minioclient::install_mc()` uses (it answers HTTP 410 Gone), so
the engine installs the pinned release from GitHub itself: `ensure_mc()` does it
when a stage or script starts (Linux and macOS, Intel or ARM), and the workflows
also run `.github/actions/install-mc` first. Both check the download against a
SHA-256. To move to a newer `mc`, change `mc_release` and the checksums in
`R/mc.R` and the defaults in `.github/actions/install-mc/action.yml` together; a
test fails if they differ. In your own scripts call `challengeci::ensure_mc()`,
not `minioclient::install_mc()`.

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

## Submissions from GitHub repositories

Optional, and used together with the submissions bucket: the `submissions`
stage reads both and keeps one processed-submissions record. It is on when the
config sets `submissions$github$registry`; set `submissions$use_bucket: false`
to read only GitHub. Nothing is needed from contributors but a public
repository: the CI never holds a credential for them, and a model id can only
be submitted from the repository registered for it.

**What a contributor does**

1. Keep forecasts in a public repository, in a folder such as `forecasts/`,
   named `<theme>-<YYYY-MM-DD>-<model_id>.csv` (or `.csv.gz`) as for the bucket.
2. Add `challenge-model.yaml` at the repository root. It names the challenge and
   its models, and carries the model metadata that the registration form asks
   for:

   ```yaml
   challenge: neon4cast            # the challenge's project_id
   models:
     - model_id: my_model
       path: forecasts/            # optional, this is the default
       long_name: My lake model
       description: A process model of lake temperature
       code_url: https://github.com/alice/forecasts
       model_type: process-based
       dynamic: true
       ic_uncertainty: true
   ```

   The keys after `path` are the questions of the registration form, by the
   short names listed in `?challengeci::registration_columns`, answered as in
   the form (`true` and `false`, or `yes` and `no`, mean the form's "Yes" and
   "No"). Leave a question out to leave it unanswered. A repository for several
   challenges lists one block per challenge, as a YAML list.
3. Register the repository, by either route:
   - **an issue** (optional, set up below): open the challenge repository's
     "Register a forecast repository" form and give the repository's address. A
     bot checks it, adds it to the registry, replies and closes the issue;
   - **by hand**: ask the operator to add a row to the registry.

**Model metadata.** `challenge-model.yaml` is also where the model metadata
comes from: the `catalog` stage's model metadata records are built from the
registration form's rows *and* the files in the registered repositories. For a
model in both, the file's answers win and the form fills any question the file
leaves out; a model only in a file needs no form, so the registration sheet
(`model_metadata_gsheet`) may be left out of the config altogether. Edits to the
file reach the catalog at its next run.

**A model id belongs to one repository.** If two registered repositories list the
same `model_id`, the first one in the registry keeps it (for submissions and for
metadata) and the other is told so in its published results.

**Registering by issue (optional).** Copy
`inst/issue_forms/register-forecast-repo.yml` to `.github/ISSUE_TEMPLATE/` and
`inst/workflows/register.yaml` to `.github/workflows/` in the challenge
repository. The workflow runs when an issue with the `register-repo` label (the
form adds it) is opened or edited, and uses only the Actions token (it needs
`contents: write` and `issues: write`, which the trigger file grants). It
registers the repository when
- it is public and has a valid `challenge-model.yaml` for this challenge, and
- none of its model ids belong to a repository already in the registry.

Then it commits a row to the registry, replies on the issue and closes it. A
model id that already has a registration through the form is not taken over
automatically: the issue gets the `needs-review` label and stays open until a
maintainer has checked that the repository belongs to the model's owner and
added the row. Any other problem is explained on the issue (label
`registration-failed`); the contributor edits the issue to try again. The registry
must be a file in the challenge repository (not a URL) for this to work. The
issue text is untrusted: it supplies only a repository name, matched against a
strict pattern, and everything else is read from the repository.

**What the operator does**

- To register by hand, add a row to the registry CSV named by
  `submissions$github$registry` (`repo,repo_id,registered`). Put the repository's
  numeric id in `repo_id` when it is known
  (`gh api repos/<owner>/<name> --jq .id`): a repository that is renamed or
  transferred keeps the same id, and one that is deleted and recreated under the old
  name does not, so it stops being read until the registry is updated. For a model
  that already submits through the bucket, check the repository really belongs to
  that model's owner before listing it: the bucket accepts any `model_id`, so
  nothing else says who owns an id.
- Give the jobs a GitHub token: the workflows already pass the Actions token as
  `GITHUB_PAT`. Without one, the API allows only 60 requests an hour.
- Remove a repository by deleting its row. A contributor can also stop at any
  time by removing `challenge-model.yaml` or making the repository private.

**How files are found.** Each run lists every registered repository's default
branch and compares each file's path with the processed-submissions record (key
`github/<repo id>/<path>`). File dates are never used. The first version of a
path wins: editing a file after it was processed has no effect, as for a bucket
key. A file's publication time is when the CI first processed it, not its commit
time. Only `.csv` and `.csv.gz` files in a registered folder are read, up to
`submissions$github$max_file_mb`, and a repository's other files are ignored.

**What submitters see.** `<forecasts_bucket>/submission_results/<model_id>.csv`
lists what happened to each file (`processed`, `invalid` with the reason,
`skipped`, ...), for the bucket and GitHub alike (see
`?challengeci::write_submission_results`). A repository whose
`challenge-model.yaml` is missing or invalid is reported in
`github_<repo id>.csv` until it is fixed.

## A private bucket

By default the engine assumes the main store is public: its stages read the
forecasts, scores and targets anonymously, and the catalog and dashboard link to
them. To keep the bucket private, set `public_read: false` in the config. Then:

- every read of the main store (bundling, scoring, the catalog, the dashboard,
  baselines and the targets check) uses the key named in `credentials`, and
  targets files are downloaded with it instead of fetched by URL. The workflows
  already pass the key to every job that needs it, including the dashboard;
- a dry run needs the key too, since nothing can be read without it
  (`OSN_KEY` and `OSN_SECRET` in `.Renviron` or the environment);
- the NOAA driver store is unaffected (it is read as before).

What a private bucket cannot do is serve participants. These parts of the
engine's output assume the data can be read by anyone, and will not work for
people without a key:

- the catalog's access code (`arrow::open_dataset()` and the Python snippet on
  each model's page) and its links to the data, the metadata JSON and the targets;
- the dashboard's and the "How to forecast" page's links to the targets files;
- the published `submission_results/` files.

Participants of a private challenge need another way to get the targets (a public
copy of just that file, or a read-only key) and to see their results.
`public_read: false` is a good fit for a store that does not answer anonymous
*list* requests, such as Backblaze B2, where the engine's own reads must use the
key even though the bucket is public.
