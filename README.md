# challenge-ci

The shared engine for Ecological Forecasting Initiative (EFI) forecasting
challenges: an R package (`challengeci`), GitHub Actions workflows and
composite actions, and the dashboard pages. It processes submissions, bundles
and scores forecasts, runs baseline models, downloads NOAA weather drivers,
and builds each challenge's STAC catalog and dashboard.

This repository holds no challenge's own files. Each challenge has its own
repository, named `<project_id>-challenge`, with its
`challenge_configuration.yaml`, targets scripts and dashboard text, and checks
itself with `challengeci::check_challenge_repo()`.

| Guide | For |
|---|---|
| [docs/configuration.md](docs/configuration.md) | every setting in a challenge's config |
| [docs/operations.md](docs/operations.md) | workflows, schedules, secrets, reruns and recovery |
| [docs/developing.md](docs/developing.md) | changing the engine |
| [docs/launching-a-new-challenge.md](docs/launching-a-new-challenge.md) | starting a new challenge |
| [AGENTS.md](AGENTS.md) | rules and known traps for anyone (or any AI agent) changing the code |

Thomas, R.Q. and C. Boettiger. (2025). Cyberinfrastructure to Support
Ecological Forecasting Challenges. ESS Open Archive.
<https://doi.org/10.22541/essoar.175917344.44115142/v1>

Supported by the U.S. National Science Foundation (DEB-1926388, OAC-2209866,
DEB-2327030 and OAC-2311124).
