#!/usr/bin/env bash
# Commit what the catalog stage wrote to $DIR and push it.
#
#   REPO    owner/name of the catalog repository
#   BRANCH  branch the catalog is kept in; empty for the clone's current branch
#   DIR     the clone made by catalog-clone
#   TOKEN   a token that can push to REPO (CATALOG_TOKEN, else the built-in token)
#   CATALOG_REMOTE_URL  optional: push to this address instead of GitHub's (for tests)
set -euo pipefail

cd "$DIR"
git config user.name github-actions
git config user.email github-actions@github.com
git add -A .
git commit -m "update catalog" || echo "nothing to commit"

if ! git rev-parse -q --verify HEAD > /dev/null; then
  echo "The catalog stage wrote nothing: nothing to push."
  exit 0
fi

target="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
url="${CATALOG_REMOTE_URL:-https://x-access-token:${TOKEN}@github.com/${REPO}.git}"

# Take in a push made since we cloned. A branch that is not on the remote yet
# has nothing to take in.
status=0
git ls-remote --exit-code --heads "$url" "refs/heads/${target}" > /dev/null || status=$?
if [ "$status" -eq 0 ]; then
  git pull --rebase "$url" "$target"
elif [ "$status" -ne 2 ]; then
  echo "Could not reach ${REPO:-the repository} (git exit status ${status})." >&2
  exit "$status"
fi

git push "$url" "HEAD:refs/heads/${target}"
