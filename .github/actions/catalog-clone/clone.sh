#!/usr/bin/env bash
# Clone the repository the catalog is committed to into $DIR.
#
#   REPO    owner/name of the catalog repository
#   BRANCH  branch to keep the catalog in; empty for the repository's default branch
#   DIR     folder to clone into
#   CATALOG_REMOTE_URL  optional: use this address instead of GitHub's (for tests)
#
# A branch that does not exist yet (the first run) is started empty: an orphan
# branch with no files of the code, so the catalog never mixes with it. Any
# other failure, such as no network or an unknown repository, stops the run.
set -euo pipefail

url="${CATALOG_REMOTE_URL:-https://github.com/${REPO}.git}"

if [ -z "${BRANCH:-}" ]; then
  git clone --depth 1 "$url" "$DIR"
  exit 0
fi

status=0
git ls-remote --exit-code --heads "$url" "refs/heads/${BRANCH}" > /dev/null || status=$?
case "$status" in
  0)
    git clone --depth 1 --branch "$BRANCH" "$url" "$DIR"
    ;;
  2)
    echo "Branch '${BRANCH}' does not exist in ${REPO:-the repository} yet: starting it empty."
    git init -q "$DIR"
    git -C "$DIR" symbolic-ref HEAD "refs/heads/${BRANCH}"
    git -C "$DIR" remote add origin "$url"
    ;;
  *)
    echo "Could not reach ${REPO:-the repository} (git exit status ${status})." >&2
    exit "$status"
    ;;
esac
