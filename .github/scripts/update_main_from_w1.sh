#!/usr/bin/env bash
#
# This script keeps the *main* branch in this repo aligned with the highest-numbered
# `w1-XX` branch in StefanMaron/MSDyn365BC.Code.History.
# It creates ONE commit that contains the diff to the previous state,
# while preserving the .github folder (so the workflow keeps working).
#
# Steps:
#   1. Ensure both remotes (origin, upstream) exist and fetch all refs
#   2. Find the highest-numbered upstream w1-XX branch
#   3. Determine the version currently stored on main
#   4. If main is outdated, update it with the latest upstream branch (preserving .github)
#   5. Commit and push the update

set -euo pipefail  # Exit on error, unset variable, or failed pipe

UPSTREAM_URL="https://github.com/StefanMaron/MSDyn365BC.Code.History.git"  # Upstream repo URL
BRANCH_PREFIX="w1-"  # Prefix for W1 branches

# --------------------------------------------------------------------
# 1) Ensure we have both remotes and all refs
# --------------------------------------------------------------------
# Add the upstream remote if it doesn't exist
# Fetch all branches from origin (our repo)
# Fetch all w1-* branches from upstream as remote-tracking branches

git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true

git fetch --quiet origin  # Fetch all refs from origin

git fetch --quiet upstream "+refs/heads/${BRANCH_PREFIX}*:refs/remotes/upstream/${BRANCH_PREFIX}*"  # Fetch all w1-* branches from upstream

# --------------------------------------------------------------------
# 2) Find the highest-numbered upstream branch (e.g. w1-26)
# --------------------------------------------------------------------
# List all remote-tracking w1-* branches from upstream, strip the prefix,
# sort numerically by the number after w1-, and pick the highest one.

latest_upstream_branch=$(git for-each-ref --format='%(refname:short)' \
                         "refs/remotes/upstream/${BRANCH_PREFIX}*" |
                         sort -t- -k2 -n | tail -1)

if [[ -z "$latest_upstream_branch" ]]; then
  echo "ERROR: no ${BRANCH_PREFIX} branches found in upstream"; exit 1
fi

echo "Newest upstream branch is $latest_upstream_branch"

# --------------------------------------------------------------------
# 3) Determine the version currently stored on main (if any)
#    We parse the latest commit message for 'w1-XX'.
# --------------------------------------------------------------------
# Check if main exists, then extract the w1-XX version from the latest commit message.
# If not found, set to 'none'.

current_version=$(git -C . rev-parse --verify -q refs/heads/main && \
                 git -C . log -1 --pretty=%B main | grep -oE "${BRANCH_PREFIX}[0-9]+" || true)
current_version=${current_version:-"none"}
echo "Current version on main is $current_version"

# If main is already up to date, exit early
if [[ "$current_version" == "$latest_upstream_branch" ]]; then
  echo "Repository already on newest version – nothing to do."
  exit 0
fi

# --------------------------------------------------------------------
# 4) Check out main and bring in upstream files
# --------------------------------------------------------------------
# Switch to main branch
# Create a temporary directory
# Archive the latest upstream branch and extract it into the temp dir
# Use rsync to copy all files from temp dir to repo, deleting files that disappeared upstream
# Exclude the .github folder from deletion to preserve workflow config

git checkout main

tmp_dir=$(mktemp -d)  # Create temp dir for upstream snapshot
git archive "$latest_upstream_branch" | tar -x -C "$tmp_dir"  # Extract upstream branch into temp dir

# Use rsync to update working directory, but keep .github folder
rsync -a --delete \
      --exclude '.github/' \
      "$tmp_dir"/ ./ > /dev/null

# Safety check before deleting tmp_dir to avoid deleting the repo by accident
if [[ -n "$tmp_dir" && "$tmp_dir" != "/" && "$tmp_dir" != "." && "$tmp_dir" != "$(pwd)" ]]; then
  rm -rf "$tmp_dir"  # Clean up temp dir
else
  echo "Refusing to delete suspicious tmp_dir: $tmp_dir"
fi

# --------------------------------------------------------------------
# 5) Stage, commit, and push the update
# --------------------------------------------------------------------
# Stage all changes
# If there are no changes, exit
# Otherwise, commit with a message indicating the new upstream version
# Push to origin/main

git add -A
if git diff --cached --quiet; then
  echo "No visible changes after rsync – aborting."
  exit 0
fi

git commit -m "Sync to upstream ${latest_upstream_branch}"

git push origin main

echo "main branch updated to ${latest_upstream_branch}"