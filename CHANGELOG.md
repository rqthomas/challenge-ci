# Changelog

Each release is tagged `vX.Y.Z` and builds the base image
`ghcr.io/eco4cast/challenge-ci:vX.Y.Z`. A challenge upgrades by changing the
version in its trigger workflows (and `ci$docker_image`, if it pins one).

Minor releases only add: new config keys are optional with defaults. A release
that needs challenges to change anything is a major release, and its section
says exactly what to change.

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
