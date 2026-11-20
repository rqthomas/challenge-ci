# The dashboard's data contract

The dashboard is a Quarto site whose pages draw their charts and tables in the
browser from small JSON files. Those files are the **contract** between the
engine (R, which reads the buckets) and the pages (`inst/dashboard/js/`, which
never do). Everything below is written by `stage_dashboard_data()` into the
site's `data/` folder (`R/dashboard_data.R` builds each file).

Why it matters:

- **Private buckets work.** R reads the bucket with the challenge's key at build
  time and writes only the files below, which are public. No key is ever sent
  to a browser, and a test checks that none reaches `meta.json`.
- **The front end can change.** A different site (another static generator, a
  Node app) needs only these files. Keep the contract stable and the pages
  replaceable.

Every file has `"schema": 1`. The pages refuse a file with another version, so
a change that breaks a reader bumps `dashboard_data_schema` in
`R/dashboard_data.R` and `SCHEMA` in `inst/dashboard/js/data.js`. Adding a
field does not need a bump; readers ignore fields they do not know.

All times are UTC ISO 8601 (`2026-11-20T14:23:00Z`), dates `YYYY-MM-DD`. A
missing number is `null`. Arrays are always arrays, even with one element.
Names used in file names (`<id>`, `<site>`, `<model>`) are slugs: anything
outside `A-Za-z0-9_.-` becomes `_`.

## Files

| File | What |
|---|---|
| `meta.json` | The challenge, its variables, sites, groups, datasets and access. Entry point of every page. |
| `models.json` | Every registered or scored model, for labels and filters. |
| `leaderboard/<id>.json` | Scores of every model for one variable, by window, horizon and date. |
| `forecasts/<id>__<site>.json` | The latest forecast and a scored one at a plot site, with observations. |
| `models/<model>.json` | One model's registration and the variables it has scores for. |
| `results/<name>.json`, `results/index.json` | What happened to each file a model submitted. Published unless `dashboard$publish_results: false`. |
| `variables.csv`, `sites.csv` | Not part of the contract: inputs of the pages that build tables in R. |

`<id>` is a variable's dashboard id: `<variable>_<duration>`, for example
`temperature_P1D`.

### `meta.json`

```text
schema, updated
challenge   {id, name, url, repo, tagline, contact_email, registration_form_url,
             example_submission_repo, key_request_url, github_submissions,
             issue_registration, catalog_url, citation}
access      {public_read, endpoint, results_published}
stats       {n_forecasts, n_models, n_active_models, n_variables, targets_start,
             targets_end, updated}
variables[] {id, variable, duration, group, long_name, description, label,
             max_horizon, baseline, windows[3]}
sites[]     {site_id, site_name, latitude, longitude, groups[]}
groups[]    {name, theme, focal_sites[], plot_sites[]}
datasets[]  {id, name, about, format, urls[], public, columns[{name, type, text}]}
leaderboard_max_horizon, min_forecasts
```

- `access.public_read` is false for a private bucket. A dataset's `public` says
  whether it can be read without a key (the results list always can: it is
  published on the site). `urls` are the HTTPS addresses in the bucket, so the
  pages can show how to read them; they carry no key.
- `variables[].baseline` is the model id skill is measured against; absent when
  the variable has none (see below). `windows` are the three leaderboard
  windows in days (7/30/90, or 90/180/365 for weekly and longer variables).
- `plot_sites` are the sites that have a `forecasts/` file.

### `leaderboard/<id>.json`

```text
schema, variable, baseline?, windows[3], updated
models   { <model_id>: {
   w {"<days>": {skill, crps, n, dates}}   one entry per window
   h {h[], skill[], crps[]}                by horizon (days), in the middle window
   t {d[], skill[], crps[]}                by forecast date, in the longest window
}}
```

- **Skill** is `1 - sum(crps of the model) / sum(crps of the baseline)` over
  the forecasts (site, reference time and valid time) that both made, so a
  model is compared with the baseline only where the baseline forecast too.
  Zero is as good as the baseline; one is no error. It is `null` when there is
  no baseline or no overlap. The baseline's own skill is 0.
- `crps` is the mean CRPS over all of the model's forecasts in the window, `n`
  the number of scores (site, reference time and lead time) and `dates` the
  number of distinct forecast dates (`min_forecasts` of them are needed to be
  ranked).
- The baseline is the group's `climatology` baseline for variables shorter
  than a week and its `weekly_climatology` for longer ones; set
  `dashboard$skill_baseline` to use one model for all. See `skill_baselines()`.
- `dashboard$excluded_models` removes models from the file.

### `forecasts/<id>__<site>.json`

```text
schema, variable, site_id, updated
obs   {t[], v[]}            observations at the site, the last 120 days
sets[] {id, reference, models {<model_id>: {d[], m[], l[], u[]}}}
```

`id` is `latest` (the newest forecast made at least two days ago, so most
models have submitted) or `scored` (the newest one that is a lookback old
enough to have observations: 30 days, or a year for weekly variables). `d` is
days after `reference`, `m` the mean, and `l`, `u` the 95% interval. Long
forecasts are thinned to at most 400 points. Numbers are rounded to 4
significant digits.

### `models/<model>.json` and `models.json`

A model's file has `model_id`, `registered`, `baseline`, `long_name`,
`description`, `model_type`, `code_url`, `contact_name` (only if the model
allows its contact to be public), `answers` (the registration's uncertainty
questions) and `variables` (ids it has scores for). `models.json` lists
`{model_id, long_name, model_type, baseline, variables[]}` for all of them. A
model with scores but no registration still gets a file, with `registered:
false`.

### `results/<name>.json`

`{schema, name, rows[{file, status, reason?, warnings?, first_seen, source?}]}`,
newest first, at most 50. `<name>` is a model id (or `github_<id>` for a
repository whose `challenge-model.yaml` cannot be read). `results/index.json`
maps each name to `{sources[], last, models[]}` so a visitor can look up their
repository (`github:owner/repo`) or a model id. These come from
`<forecasts_bucket>/submission_results/` (see `write_submission_results()`).
They list file names and reasons, never forecasts.

## Changing the contract

1. Change the builder in `R/dashboard_data.R` and its test in
   `tests/testthat/test-dashboard_data.R`.
2. Change this page.
3. Change the readers in `inst/dashboard/js/` (`data.js` loads, `board.js`
   ranks).
4. Bump the schema only if an existing reader would break.

To try a front-end change without any bucket, build a folder with
`stage_dashboard_data()` once, then `render_dashboard(cfg, data_dir = ...)`
(see `docs/developing.md`).
