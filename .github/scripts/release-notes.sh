#!/usr/bin/env bash
# Writes Markdown release notes (changelog since the previous release) to stdout.
# Usage: release-notes.sh <app> <version> <build> <tag-glob> <this-tag> <install-line>
set -euo pipefail
APP=$1 VERSION=$2 BUILD=$3 GLOB=$4 THIS_TAG=$5 INSTALL=$6

PREV=$(git describe --tags --abbrev=0 --match "$GLOB" --exclude "$THIS_TAG" HEAD 2>/dev/null || true)

echo "## $APP $VERSION (build $BUILD)"
echo
if [ -n "$PREV" ]; then
  echo "### Changes since $PREV"
  LOG=$(git log "$PREV..HEAD" --no-merges --pretty='- %s (%h)')
else
  echo "### Changes"
  LOG=$(git log HEAD --no-merges --pretty='- %s (%h)')
fi
echo
if [ -n "$LOG" ]; then
  echo "$LOG" | head -n 60
else
  echo "- No code changes since $PREV (rebuild)"
fi
echo
echo "---"
echo "Built from \`$(git rev-parse --short HEAD)\`. $INSTALL"
