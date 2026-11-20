# Launching a new challenge

A challenge is its own repository, named `<project_id>-challenge`, that uses a
released version of this engine. It holds only what is specific to the
challenge:

```
challenge_configuration.yaml   every setting (configuration.md)
<site metadata>.csv            the sites (or a URL in the config)
challenge/targets/             one script per target group, plus helpers
challenge/dashboard/           dashboard text and images (see ?render_dashboard)
challenge/catalog/             e.g. descriptions of the site metadata columns
challenge/Dockerfile           optional: packages beyond the engine's base image
.github/workflows/             trigger workflows: schedules only
.gitignore                     must list .Renviron
```

Engine improvements reach it by changing one version number, never by merging.
Work through the steps with `DRY_RUN=true` (see [developing.md](developing.md))
so nothing is written to S3 until you are ready.

## 1. Create the repository

Press *Use this template* on
[`eco4cast/challenge-template`](https://github.com/eco4cast/challenge-template)
and name the repository `<project_id>-challenge`. The template is a small
working challenge (one target group, three lakes): its README shows how to
dry-run it, which is a quick way to see every stage work before you change
anything. Its trigger workflows have their schedules commented out, so nothing
runs until step 12.

Without the template, start an empty repository with the layout above, copy
the trigger workflows you need from the engine's `inst/workflows/` into
`.github/workflows/` and set the engine version after `@` in each (e.g.
`@v0.1.0`). Leave out the drivers triggers if you provide no NOAA weather
forecasts. Make sure `.gitignore` lists `.Renviron`.

## 2. Describe the sites

Make a CSV with one row per site. It needs a site id, name, latitude and
longitude (any column names; map them in `sites$columns`), plus one column per
target group holding `1` for sites in that group. Name each such column after
the group in lower case, or set the group's `sites_column`. Commit it, and set
`sites$metadata_url` to its raw URL (or a path in the repository).

## 3. Write the configuration

Edit `challenge_configuration.yaml`; [configuration.md](configuration.md)
describes every key. The keys that make up a challenge:

| Section | Set |
|---|---|
| Identity | `project_id` (short, used in every path and row), `challenge_long_name`, `github_repo` (this repository), `challenge_url` (where the dashboard is published) |
| Storage | `endpoint` and the `*_bucket` keys for the main store; `submissions_endpoint` and `submissions_bucket` (only if you accept uploads to a bucket); `scratch` for scoring; `credentials` if your secrets have other names |
| Sites | `sites$metadata_url`, `sites$columns` |
| Target groups | for each group: `variable`, `duration`, `max_horizon` (days), `targets_file`, `targets_script`, `theme` (file-name prefix participants use), `focal_sites`, `baselines`, and the catalog's `thumbnail_link`/`thumbnail_title` and `group_vars` citations |
| Submissions | `submissions$github$registry` (read forecasts from contributors' GitHub repositories, see [operations.md](operations.md#submissions-from-github-repositories)), `submissions$use_bucket: false` (GitHub only), `submissions$baselines_destination: forecasts_bucket` (baselines need no submissions key), `submissions$min_reference_date`, `submissions$exclude_patterns`; `submissions$known_themes_only: true` if the submissions bucket is shared with another challenge |
| Drivers | `noaa_forecast_bucket`, `noaa_endpoint`, `noaa_forecasts` (only if you provide NOAA weather forecasts) |
| Metadata | `model_metadata_gsheet`, `target_metadata_gsheet` (step 6) |
| Dashboard | `dashboard` block: title, contact email, registration form, excluded models, extra pages |
| Catalog | `catalog_config`: catalog repository and folder, titles, thumbnails, citation, bounding box |
| Workflows | `ci`: container image, large runner (or `ubuntu-latest`), healthcheck URLs |

Then check the repository from its root:

```sh
Rscript -e 'challengeci::run_stage()' check
```

## 4. Create the storage

Create the buckets named in the config. The main store's forecasts, scores,
summaries, targets and metadata buckets must allow **anonymous read**: the
dashboard, catalog and participants read them without credentials. The
submissions bucket (if you use one) must let participants upload. The scratch bucket is private
and holds temporary files while scoring.

**Backblaze B2.** The S3 API works with the engine: use the endpoint
`s3.<region>.backblazeb2.com` (the region is read from it), name the bucket
in the `*_bucket` settings, and make it public for downloads. B2 does not, as far
as we know, answer anonymous *list* requests, so either set `public_read: false`
(the engine then reads with the key; participants cannot read the folders
anonymously) or check
`curl 'https://s3.<region>.backblazeb2.com/<bucket>/?list-type=2&max-keys=1'`
before choosing it for a public challenge: reads that open a folder of parquet
files without credentials (the engine's anonymous reads, the catalog's access
code for participants) need listing.

## 5. Add the secrets and tokens

The workflows read their credentials from **repository secrets** of the challenge
repository. Nothing secret ever goes in the config, a workflow or the code: the
config holds only the *names* of the environment variables (`credentials`).

**To add a secret:** on github.com open the repository's **Settings → Secrets and
variables → Actions → New repository secret**, or run
`gh secret set <NAME> -R <owner>/<repository>` and paste the value when asked.
A secret's value cannot be read back, so keep the original somewhere safe (a
password manager). Tokens expire: note the date, and renew them before it.

### What you need

| Secret | Needed when | What it is |
|---|---|---|
| `OSN_KEY`, `OSN_SECRET` | **always** (targets, baselines, submissions, bundling, scoring, catalog, drivers; the dashboard only with `public_read: false`) | The key ID and secret of an S3 key that can read and write the **main store** (the buckets named in the config). The names are historical: they hold the key of whichever store `endpoint` is. See *The store key*. |
| `EFI_NRP_KEY`, `EFI_NRP_SECRET` | scoring and targets, **unless** the scratch space uses the main key | The key for the `scratch` store. If scratch is in the main bucket (as in the template) set `credentials: scratch: {key_env: OSN_KEY, secret_env: OSN_SECRET}` in the config and skip these two. |
| `AWS_ACCESS_KEY_SUBMISSIONS`, `AWS_SECRET_ACCESS_KEY_SUBMISSIONS` | only if participants upload to a **submissions bucket** (`submissions$use_bucket` not `false`) or baselines go through it (`baselines_destination: submissions_bucket`) | A key for the `submissions_endpoint` store. A challenge that takes submissions from GitHub repositories and writes baselines straight to the forecasts bucket does not need it. |
| `CATALOG_TOKEN` | only for the `catalog` workflow | A GitHub token that can push to the catalog repository. See *GitHub tokens*. |
| `WORKFLOW_TOKEN` | only for the `update-engine` workflow | A GitHub token that can change workflow files and open pull requests in this repository. See *GitHub tokens*. |
| `NEON_TOKEN` | NEON-based targets scripts | A NEON API token: sign in at [data.neonscience.org](https://data.neonscience.org), open *Get an API token* in your account, and copy it. |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | only if your own image (`challenge/Dockerfile`) is pushed to **Docker Hub** | Your Docker Hub user name and an access token (Docker Hub → Account settings → Security → New access token, with write access). An image on `ghcr.io` needs neither. |
| `PAT` | optional, for building your own image | A GitHub token for installing packages from GitHub during the build without rate limits. |

Participants of a **private** challenge also need a key (see *Participants'
keys*), and the engine's maintainers need two more (see *Engine maintainers*).
For local runs put the same names in `.Renviron` at the repository root, which R
reads at startup and which is never committed:

```
OSN_KEY=...
OSN_SECRET=...
```

### The store key

Create it in your S3 provider and give it access to the bucket only.

- **Backblaze B2:** in the Backblaze account open **Application Keys → Add a New
  Application Key**; name it, set *Allow access to Bucket(s)* to your bucket, and
  *Type of Access* to **Read and Write**; create it. B2 shows the **keyID** and the
  **applicationKey** only once: the keyID is `OSN_KEY`, the applicationKey is
  `OSN_SECRET`.
- **Other S3 stores** (OSN, AWS, Ceph): an access key ID and a secret key for a user
  or role that can list, read, write and delete in the bucket.

Keep a separate, **read-only** key for anyone who only needs to read a private
bucket; never hand out this one.

### GitHub tokens

`CATALOG_TOKEN` and `WORKFLOW_TOKEN` are **fine-grained personal access tokens**.
The built-in `GITHUB_TOKEN` cannot do what they do (push to another repository,
change files under `.github/workflows`, open a pull request that starts the
checks). To create one:

1. On github.com click your profile picture → **Settings → Developer settings →
   Personal access tokens → Fine-grained tokens → Generate new token**.
2. Give it a name, set **Resource owner** to the account or organization that
   owns the repository, and set an **expiration** (renew it then).
3. Under **Repository access** choose **Only select repositories** and pick the
   repository from the table below.
4. Under **Repository permissions** set the permissions from the table to *Read and
   write*, then **Generate token** and copy it straight away; GitHub shows it once.
5. Store it as the secret named in the table (`gh secret set NAME -R <owner>/<repo>`).
   An organization may have to approve fine-grained tokens first.

| Secret | Repository access | Permissions |
|---|---|---|
| `CATALOG_TOKEN` | the **catalog** repository only | Contents |
| `WORKFLOW_TOKEN` | the **challenge** repository only | Contents, Pull requests, Workflows |

### No token needed, but check

- **The built-in `GITHUB_TOKEN`** is used for the dashboard (pushing to `gh-pages`)
  and registration by issue (committing the registry, commenting). The trigger
  workflows already ask for the permissions they need. If a run fails with a 403,
  allow it in **Settings → Actions → General → Workflow permissions** (*Read and
  write permissions*; in the organization's settings if the option is greyed out).
- **The engine's container image** must be readable by your workflows. A package
  that `ghcr.io/<owner>/challenge-ci` publishes is private by default, and a private
  image makes every job fail at "Initialize containers". In the package's settings
  (github.com → your profile or organization → **Packages** → `challenge-ci` →
  **Package settings**) either set the visibility to **Public** (the image holds
  nothing secret) or add the challenge repository under *Manage Actions access*.
  Do the same for your own image if you build one.

### Participants' keys

If the main bucket is **private**, participants need a way to read the targets. Give
each of them (or share one) a **read-only** store key, created as in *The store key*
with *Type of Access* **Read Only**. In their own repository it goes in as the
secrets `S3_KEY` and `S3_SECRET`; the example submission's `forecast.R` reads them.
A public bucket needs no key. Submitting from GitHub needs no token at all.

### Engine maintainers

The engine repository (`challenge-ci`) has its own secrets, only for the people who
release it:

| Secret | Used by | What it is |
|---|---|---|
| `RELEASE_TOKEN` | the `release` workflow | A fine-grained token for the **engine** repository with *Contents* and *Workflows* read and write (the release commit changes workflow files). |
| `TEMPLATE_TOKEN` | `template-check` | A token that can read the template repository, only while it is private. Optional once it is public. |

## 6. Set up registration and variable metadata

- **Registration form.** Participants register models with a Google Form whose
  responses go to a sheet readable by anyone with the link; set
  `model_metadata_gsheet` to it. The EFI form is shared by several challenges
  and has a question naming the challenge; only rows whose answer equals your
  `project_id` are used. If your form words a question differently, map it in
  `catalog_config$registration_columns` (`?challengeci::registration_columns`).
- **Variable sheet.** One row per variable and duration with columns
  `Variable name` (long name), `"official" targets name` (the variable),
  `Description` and `duration`; set `target_metadata_gsheet`. Different column
  names go in `catalog_config$variable_metadata_columns`.

## 7. Write the targets scripts

For each target group, write `challenge/targets/<group>_targets.R` and name it
in the group's `targets_script`. A script downloads and cleans the observations
any way it needs to, and ends the same way as every other:

```r
# <Group> targets from <source>.
#
# Run from the repository root:  Rscript challenge/targets/<group>_targets.R
#
# Environment variables
#   OSN_KEY, OSN_SECRET  main store, for the upload
#   DRY_RUN=true         write the targets to a local folder instead

library(challengeci)
cfg <- read_config()
ensure_mc()      # the MinIO client, installed from GitHub if missing
sites <- read_sites(cfg, "<Group>")

observations <- ...  # site_id, datetime, variable, observation

observations |>
  format_targets(cfg, duration = "P1D") |>  # standard columns and types
  check_targets(cfg, "<Group>") |>          # stops if rows, sites or variables went missing
  write_targets(cfg, "<Group>")             # uploads to the group's targets_file
```

`check_targets()` compares the new targets with the published file and refuses
to upload if they lost more than 5% of the rows, a site or a variable. Put
helpers in `challenge/targets/R/`. Set `targets_large_runner: true` for a group
that needs more than a GitHub runner's 16 GB of memory or 6 hours. If the
scripts need R packages the base image lacks, add them in
`challenge/Dockerfile` (`FROM ghcr.io/eco4cast/challenge-ci:<version>`) and
set `ci$docker_image` to the image the `docker.yaml` trigger builds.

## 8. Write the dashboard text

In `challenge/dashboard/` (see `?challengeci::render_dashboard`):

- `_content/home.qmd` and `_content/home-more.qmd`: the home page text above
  and below the headline numbers;
- `_content/targets/<Group>.md`: an image and a few paragraphs about each group;
- `_content/instructions-drivers.qmd`, `-automation.qmd`, `-examples.qmd`,
  `-submit.qmd`: the challenge's sections of the instructions page;
- `img/banner.jpg`: the banner;
- any extra pages (`*.qmd`), listed in `dashboard$extra_pages`.

Any file you leave out falls back to the engine's generic default. Preview the
site with `Rscript -e 'challengeci::run_stage()' dashboard site` and open
`site/index.html`.

## 9. Set up publishing

### The catalog

The `catalog` workflow builds the challenge's STAC catalog (browsable at
[radiantearth.github.io/stac-browser](https://radiantearth.github.io/stac-browser))
and commits it to a **separate repository**, which must exist before the first
run, even for a dry run (the workflow clones it first). You can skip the catalog
altogether by never running that workflow: the forecasts, scores and dashboard do
not depend on it, but the dashboard's catalog page then links to nothing, and the
model metadata records (`<model_metadata_bucket>/<model_id>.json`), which the
same stage writes from the registrations, are not updated. (`run_stage()` with
`catalog metadata` writes only those, and needs no catalog repository.)

1. **Create the repository**, public, *with a README* so that it has a `main`
   branch (the catalog's links assume `main`):
   ```sh
   gh repo create <owner>/<name>-catalog --public --add-readme \
     --description "STAC catalog for <challenge name>"
   ```
2. **Point the config at it:** `catalog_config$catalog_repo` is `<owner>/<name>-catalog`,
   and `catalog_config$catalog_path` is the folder name the workflow clones it
   into, normally the repository name (the `*_path` settings below it start with
   the same name).
3. **Give the workflow a token to push to it:** create `CATALOG_TOKEN` as described
   in [step 5](#github-tokens) (a fine-grained token for the catalog repository,
   with *Contents: Read and write*) and store it in the **challenge** repository.
   The workflow reads it as `EXTERNAL_GH_PAT`.

### The dashboard (GitHub Pages)

The `dashboard` workflow builds the site and pushes it to the `gh-pages` branch
of the challenge repository; GitHub Pages then serves that branch. The workflow
does **not** create the branch, so it must exist before the first run, and Pages
must be told to serve it. Do these four things once. The repository must be
public (Pages on a private repository needs a paid GitHub plan).

**1. Create the `gh-pages` branch.** From a clone of the challenge repository
(replace `main` if your default branch has another name):

```sh
git switch --orphan gh-pages          # a branch with no history or files
touch .nojekyll                       # tells Pages to serve the files as they are
git add .nojekyll
git commit -m "Create gh-pages"
git push -u origin gh-pages
git switch main                       # back to the code
```

Commit or stash any uncommitted changes first: `git switch --orphan` removes the
tracked files from your working folder until you switch back (they are not lost).
`gh-pages` holds only the built site; never edit it by hand. (If the push is
refused, check that you may push to the repository.)

**2. Turn on GitHub Pages for it.** In the repository on github.com, open
**Settings → Pages**. Under *Build and deployment* set **Source** to *Deploy from a
branch*, **Branch** to `gh-pages` and the folder to `/ (root)`, and click
**Save**. The page now shows the address of the site,
`https://<owner>.github.io/<repository>/`.

**3. Allow the workflow to push.** The `dashboard` trigger workflow asks for
`permissions: contents: write`, which is enough unless your organization limits
what workflows may do. If a run fails with a 403 on the push, open
**Settings → Actions → General → Workflow permissions** (in the repository, and
in the organization's settings if the option is greyed out) and choose *Read and
write permissions*.

**4. Set `challenge_url`** in `challenge_configuration.yaml` to the address from
step 2 (or your own domain, if you add one under **Settings → Pages → Custom
domain**). The site's links and sitemap use it.

**Publish it.** Open the repository's **Actions** tab, choose the *dashboard*
workflow, click **Run workflow** and leave *Dry run* **unticked**. It builds the
site, commits it to `gh-pages` and pushes. A second run named *pages build and
deployment* then appears; when it finishes (a minute or two) the site is live at
the address from step 2. After that the daily schedule keeps it current.

*If something goes wrong*

| Symptom | Cause and fix |
|---|---|
| The workflow fails at "Publish to gh-pages" with `pathspec 'gh-pages' did not match` | The branch does not exist on GitHub: do step 1 and push it. |
| The push fails with 403 | Workflows may not write: do step 3. |
| The workflow is green but the address shows 404 | Pages is not serving the branch (step 2), or the first deployment has not finished; look for *pages build and deployment* in Actions. |
| The site is up but unstyled or its pages are missing | `.nojekyll` is missing from the root of `gh-pages`; add it (step 1) and run the workflow again. |
| The site shows old content | Run the workflow again; browsers and GitHub cache pages for a few minutes. |

To check the site before publishing, run the workflow with *Dry run* ticked: the
built site is attached to the run as the `dry-run-dashboard` artifact.

## 10. Set the schedules

Edit the `cron:` lines in your trigger workflows
([operations.md](operations.md#workflows) lists the engine's defaults). If you
change the baselines trigger's weekly cron, change the same string in its
`schedule:` expression too. Without `noaa_forecasts` in the config, the catalog
leaves out its NOAA collection.

## 11. Dry-run every stage

From the repository root, with the secrets in `.Renviron` (or none, for the
stages that only read public data):

```sh
export DRY_RUN=true DRY_RUN_DIR=/tmp/dry-run
Rscript challenge/targets/<group>_targets.R        # one per group
Rscript -e 'challengeci::run_stage()' baselines daily   # and weekly
Rscript -e 'challengeci::run_stage()' submissions
Rscript -e 'challengeci::run_stage()' bundle
Rscript -e 'challengeci::run_stage()' score
Rscript -e 'challengeci::run_stage()' catalog
Rscript -e 'challengeci::run_stage()' dashboard site
```

In a dry run, later stages read the targets that the targets scripts wrote to
`DRY_RUN_DIR`, so the whole pipeline runs before anything is published. Until
the first forecasts exist, bundling, scoring and the catalog find nothing to
do and say so; run them again once real data are in.

## 12. Turn it on

Push, then run each trigger workflow once by hand from the Actions tab with
*dry run* ticked (the `check` workflow already runs on every push), in pipeline order: target-generation, baseline-forecasts,
process-submissions, bundling, scoring, catalog, dashboard. Then run each once
for real. Once they pass, uncomment the `schedule:` lines and the schedules
take over. Add healthcheck URLs to
`ci$healthchecks` for the jobs you want to be alerted about.
