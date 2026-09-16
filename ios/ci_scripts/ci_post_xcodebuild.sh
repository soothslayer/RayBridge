#!/bin/sh
set -eu
# Xcode Cloud discovers this hook beside RayBridge.xcodeproj.
# Build/test actions have no archive to inspect.
if [ -n "${CI_ARCHIVE_PATH:-}" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    /usr/bin/python3 "$SCRIPT_DIR/../../scripts/verify-ios-archive.py" "$CI_ARCHIVE_PATH"
elif [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    echo "Archive validation failed: Xcode Cloud did not provide CI_ARCHIVE_PATH." >&2
    exit 1
fi
