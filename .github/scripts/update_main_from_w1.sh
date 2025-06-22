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

echo "🚀 Starting Business Central W1 branch sync process"
echo "Upstream: $UPSTREAM_URL"
echo "Branch prefix: $BRANCH_PREFIX"
echo "Working directory: $(pwd)"
echo ""

# --------------------------------------------------------------------
# 1) Ensure we have both remotes and all refs
# --------------------------------------------------------------------
echo "=== Step 1: Setting up remotes and fetching refs ==="

# Add the upstream remote if it doesn't exist
echo "Adding upstream remote: $UPSTREAM_URL"
if git remote add upstream "$UPSTREAM_URL" 2>/dev/null; then
  echo "✓ Upstream remote added successfully"
else
  echo "✓ Upstream remote already exists"
fi

# List current remotes for debugging
echo "Current remotes:"
git remote -v

# Fetch all branches from origin (our repo)
echo "Fetching from origin..."
git fetch --quiet origin
echo "✓ Origin fetch completed"

# Fetch all w1-* branches from upstream as remote-tracking branches
echo "Fetching w1-* branches from upstream..."
git fetch --quiet upstream "+refs/heads/${BRANCH_PREFIX}*:refs/remotes/upstream/${BRANCH_PREFIX}*"
echo "✓ Upstream w1-* branches fetch completed"

# Debug: Show what branches we got from upstream
echo "Available upstream w1-* branches:"
git for-each-ref --format='  %(refname:short)' "refs/remotes/upstream/${BRANCH_PREFIX}*" || echo "  No w1-* branches found"

# --------------------------------------------------------------------
# 2) Find the highest-numbered upstream branch (e.g. w1-26)
# --------------------------------------------------------------------
echo ""
echo "=== Step 2: Finding highest-numbered upstream branch ==="

# List all remote-tracking w1-* branches from upstream, strip the prefix,
# sort numerically by the number after w1-, and pick the highest one.
echo "Processing upstream branches to find the latest..."

latest_upstream_branch=$(git for-each-ref --format='%(refname:short)' \
                         "refs/remotes/upstream/${BRANCH_PREFIX}*" |
                         sort -t- -k2 -n | tail -1)

echo "Debug: Found branches (sorted by version):"
git for-each-ref --format='  %(refname:short)' "refs/remotes/upstream/${BRANCH_PREFIX}*" | sort -t- -k2 -n || echo "  No branches found"

if [[ -z "$latest_upstream_branch" ]]; then
  echo "❌ ERROR: no ${BRANCH_PREFIX} branches found in upstream"
  echo "Debug: Checking what refs we have from upstream:"
  git for-each-ref --format='  %(refname)' "refs/remotes/upstream/*" || echo "  No upstream refs found"
  exit 1
fi

echo "✓ Newest upstream branch is: $latest_upstream_branch"

# --------------------------------------------------------------------
# 3) Determine the version currently stored on main (if any)
#    We parse the latest commit message for 'w1-XX'.
# --------------------------------------------------------------------
echo ""
echo "=== Step 3: Checking current version on main ==="

# Check if main exists, then extract the w1-XX version from the latest commit message.
# If not found, set to 'none'.
echo "Checking main branch for current version..."

if git rev-parse --verify -q refs/heads/main >/dev/null; then
  echo "✓ Main branch exists"
  latest_commit_msg=$(git log -1 --pretty=%B main)
  echo "Latest commit message on main:"
  echo "  $latest_commit_msg"

  current_version=$(echo "$latest_commit_msg" | grep -oE "${BRANCH_PREFIX}[0-9]+" || true)
  if [[ -n "$current_version" ]]; then
    echo "✓ Found version in commit message: $current_version"
  else
    echo "⚠ No version found in commit message"
    current_version="none"
  fi
else
  echo "⚠ Main branch does not exist yet"
  current_version="none"
fi

echo "Current version on main: $current_version"
echo "Latest upstream version: $latest_upstream_branch"

# If main is already up to date, exit early
if [[ "$current_version" == "$latest_upstream_branch" ]]; then
  echo "✓ Repository already on newest version – nothing to do."
  exit 0
fi

echo "🔄 Update needed: $current_version → $latest_upstream_branch"

# --------------------------------------------------------------------
# 4) Check out main and bring in upstream files
# --------------------------------------------------------------------
echo ""
echo "=== Step 4: Updating repository with upstream content ==="

# Switch to main branch
echo "Checking out main branch..."
git checkout main
echo "✓ On main branch"

# Create a temporary directory
echo "Creating temporary directory for upstream snapshot..."
tmp_dir=$(mktemp -d)
echo "✓ Temporary directory created: $tmp_dir"

# Archive the latest upstream branch and extract it into the temp dir
echo "Extracting upstream branch '$latest_upstream_branch' to temp directory..."
git archive "$latest_upstream_branch" | tar -x -C "$tmp_dir"
echo "✓ Upstream content extracted to: $tmp_dir"

# Debug: Show what we got from upstream
echo "Debug: Contents of upstream snapshot:"
ls -la "$tmp_dir" | head -10  # Show first 10 items
echo "  ... (showing first 10 items only)"

# Use rsync to copy all files from temp dir to repo, deleting files that disappeared upstream
# Exclude the .github folder from deletion to preserve workflow config
echo "Syncing upstream content to repository (preserving .github folder)..."
rsync -av --delete \
      --exclude '.github/' \
      "$tmp_dir"/ ./
echo "✓ Content synchronization completed"

# Safety check before deleting tmp_dir to avoid deleting the repo by accident
echo "Cleaning up temporary directory..."
if [[ -n "$tmp_dir" && "$tmp_dir" != "/" && "$tmp_dir" != "." && "$tmp_dir" != "$(pwd)" ]]; then
  rm -rf "$tmp_dir"
  echo "✓ Temporary directory cleaned up"
else
  echo "❌ Refusing to delete suspicious tmp_dir: $tmp_dir"
  exit 1
fi

# --------------------------------------------------------------------
# 5) Stage, commit, and push the update
# --------------------------------------------------------------------
echo ""
echo "=== Step 5: Committing and pushing changes ==="

# Stage all changes
echo "Staging all changes..."
git add -A
echo "✓ Changes staged"

# Debug: Show what will be committed
echo "Debug: Files that will be committed:"
git diff --cached --name-status | head -20  # Show first 20 changed files
if [[ $(git diff --cached --name-only | wc -l) -gt 20 ]]; then
  echo "  ... and $(($(git diff --cached --name-only | wc -l) - 20)) more files"
fi

# If there are no changes, exit
if git diff --cached --quiet; then
  echo "ℹ️ No visible changes after rsync – aborting."
  exit 0
fi

# Otherwise, commit with a message indicating the new upstream version
echo "Creating commit for sync to $latest_upstream_branch..."
git commit -m "Sync to upstream ${latest_upstream_branch}"
echo "✓ Commit created successfully"

# Push to origin/main
echo "Pushing changes to origin/main..."
git push origin main
echo "✅ Push completed successfully"

echo ""
echo "🎉 main branch updated to ${latest_upstream_branch}"