# syntax=docker/dockerfile:1
# The engine's base image: R, everything the challengeci package and the
# dashboard need, and the package itself. Challenges that need more (their
# targets scripts' packages, tools for participants) build a layer FROM this
# image (challenge/Dockerfile in the challenge repo, built by _docker.yaml).
#
# A versioned rocker tag also fixes the CRAN snapshot install2.r uses, so a
# rebuild installs the same package versions; rocker/geospatial includes the
# tidyverse, sf and Quarto. To upgrade, change the tag (see
# https://hub.docker.com/r/rocker/geospatial/tags) and the commits below.
FROM rocker/geospatial:4.6.2

ENV AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

RUN apt-get update && apt-get -y install --no-install-recommends libnetcdf-dev libuv1-dev \
    && update-ca-certificates && rm -rf /var/lib/apt/lists/*

# Package dependencies, then the dashboard's.
RUN install2.r --error devtools remotes pkgload desc httr2 paws.storage duckdbfs \
    fable fabletools tsibble imputeTS scoringRules \
    patchwork ggiraph bslib bsicons leaflet

# GitHub installs authenticate with the build secret `github_pat` so they are
# not rate-limited; a secret mount is never stored in the image. Each package is
# pinned to a commit; bump one deliberately to upgrade.
RUN --mount=type=secret,id=github_pat \
    export GITHUB_PAT="$(cat /run/secrets/github_pat 2>/dev/null)" && \
    R -e "remotes::install_github('mitchelloharawild/distributional', ref = 'bb0427e')" && \
    R -e "remotes::install_github('eco4cast/score4cast@f33c9e1352ad40bd743c072eb27c770bd18b0abe', upgrade = FALSE)" && \
    R -e "remotes::install_github('appelmar/gdalcubes@1193cbaead912277a8d7473ee7e538584431f5b6', upgrade = FALSE)" && \
    R -e "remotes::install_github('eco4cast/gefs4cast@6eb7675a95a3d8b1e604470f16dcbc182b1b4cd9', upgrade = FALSE)" && \
    R -e "remotes::install_github('cboettig/duckdbfs@0b48916e7b4085d951318e2bd42d14c9433fa182', upgrade = FALSE)"

# arrow is deliberately not pinned: the image gets the current CRAN release.
# The old pin (20.0.0) cannot compile on R 4.6 (it uses ATTRIB, removed from
# R's C API), and install.packages() only warns on failure, so it was never
# really in effect. arrow only reads from S3 (every upload goes through mc),
# so its S3 write problems on OSN do not matter. If a pin is ever needed
# again, make the build fail when it does not install:
#   R -e "stopifnot(packageVersion('arrow') == 'X.Y.Z')"

# The challengeci package itself (only the package files; see .dockerignore).
COPY . /tmp/challengeci
RUN R CMD INSTALL --no-test-load /tmp/challengeci && rm -rf /tmp/challengeci
