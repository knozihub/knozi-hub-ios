#!/usr/bin/env bash
# Syncs the shared Knozi Hub web assets into the iOS bundle staging dir
# (App/Resources/www). The iOS shell never edits these files — it bundles
# exactly what the Android app ships.
#
# Two sources, in order:
#   1. $ANDROID_ASSETS_DIR — a local checkout of the Android assets dir
#      (default on the dev machine: ~/workspace/apk-build/CleanConcept/app/src/main/assets).
#      Use this for local builds and for CI when both trees live in one repo.
#   2. Fallback: download the latest PUBLIC Android APK from knozihub.com/download
#      (302 -> the R2-hosted latest release) and extract its assets/ dir.
#      This keeps the iOS background track byte-identical to the shipped Android
#      build with zero repo coupling.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW="$HERE/../App/Resources/www"
TMP=""

cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$WWW"

if [ -n "${ANDROID_ASSETS_DIR:-}" ] && [ -d "${ANDROID_ASSETS_DIR}" ]; then
  echo "Syncing web assets from ANDROID_ASSETS_DIR=${ANDROID_ASSETS_DIR}"
  rm -rf "$WWW"
  mkdir -p "$WWW"
  cp -R "${ANDROID_ASSETS_DIR}/." "$WWW/"
else
  echo "ANDROID_ASSETS_DIR not set — downloading latest public APK from knozihub.com/download"
  TMP="$(mktemp -d)"
  curl -sSL --fail -o "$TMP/app.apk" "https://knozihub.com/download"
  # Sanity: must be a zip containing the web entry point.
  unzip -l "$TMP/app.apk" "assets/index.html" > /dev/null
  rm -rf "$WWW"
  mkdir -p "$WWW"
  unzip -qo "$TMP/app.apk" "assets/*" -d "$TMP/apk"
  cp -R "$TMP/apk/assets/." "$WWW/"
fi

# The three player pages must be present or the bundle is useless.
for f in index.html knozi-abc.html knozi-storybook.html; do
  if [ ! -f "$WWW/$f" ]; then
    echo "FATAL: $f missing after sync — aborting" >&2
    exit 1
  fi
done

echo "Assets synced into App/Resources/www ($(du -sh "$WWW" | cut -f1))"
