#!/usr/bin/env bash
#
# Keep the *main* branch in this repo aligned with the highest-numbered
# `w1-XX` branch in StefanMaron/MSDyn365BC.Code.History.
# Creates ONE commit that contains the diff to the previous state,
# while preserving the .github folder (so the workflow keeps working).

set -euo pipefail

UPSTREAM_URL="https://github.com/StefanMaron/MSDyn365BC.Code.History.git"
BRANCH_PREFIX="w1-"

# --------------------------------------------------------------------
# 1) Ensure we have both remotes and all refs
# --------------------------------------------------------------------
git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
git fetch --quiet origin
git fetch --quiet upstream "+refs/heads/${BRANCH_PREFIX}*:${BRANCH_PREFIX}*"

# --------------------------------------------------------------------
# 2) Find the highest-numbered upstream branch (e.g. w1-26)
# --------------------------------------------------------------------
latest_upstream_branch=$(git for-each-ref --format='%(refname:short)' \
                         "refs/remotes/upstream/${BRANCH_PREFIX}*" |
                         sed -E "s#refs/remotes/upstream/##" |
                         sort -t- -k2 -n | tail -1)

if [[ -z "$latest_upstream_branch" ]]; then
  echo "ERROR: no ${BRANCH_PREFIX} branches found in upstream"; exit 1
fi
echo "Newest upstream branch is $latest_upstream_branch"

# --------------------------------------------------------------------
# 3) Determine the version currently stored on main (if any)
#    We parse the latest commit message for 'w1-XX'.
# --------------------------------------------------------------------
current_version=$(git -C . rev-parse --verify -q refs/heads/main && \
                 git -C . log -1 --pretty=%B main | grep -oE "${BRANCH_PREFIX}[0-9]+" || true)
current_version=${current_version:-"none"}
echo "Current version on main is $current_version"

if [[ "$current_version" == "$latest_upstream_branch" ]]; then
  echo "Repository already on newest version – nothing to do."
  exit 0
fi

# --------------------------------------------------------------------
# 4) Check out main and bring in upstream files
# --------------------------------------------------------------------
git checkout main

# Snapshot upstream into a temporary worktree
tmp_dir=$(mktemp -d)
git archive "upstream/$latest_upstream_branch" | tar -x -C "$tmp_dir"

# Copy files over, deleting everything that disappeared upstream,
# but KEEP the .github folder in our repo.
rsync -a --delete \
      --exclude '.github/' \
      "$tmp_dir"/ ./ > /dev/null

rm -rf "$tmp_dir"

# Stage & commit
git add -A
if git diff --cached --quiet; then
  echo "No visible changes after rsync – aborting."
  exit 0
fi

git commit -m "Sync to upstream ${latest_upstream_branch}"

# --------------------------------------------------------------------
# 5) Push the update
# --------------------------------------------------------------------
git push origin main
echo "main branch updated to ${latest_upstream_branch}"