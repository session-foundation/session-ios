#!/usr/bin/env bash

set -e

green="\e[32;1m"

if echo "${DRONE_COMMIT_MESSAGE}" | grep -q -F "[Reset SPM]"; then
  echo "Trigger phrase found in commit message. Clearing SPM caches..."

  echo "--> Clearing global SwiftPM caches..."
  rm -rf /Users/drone/.swiftpm || echo "Warning: Failed to remove Users/drone/.swiftpm"
  rm -rf /Users/drone/Library/org.swift.swiftpm || echo "Warning: Failed to remove Users/drone/Library/org.swift.swiftpm"
  rm -rf /Users/drone/Library/Caches/org.swift.swiftpm || echo "Warning: Failed to remove Users/drone/Library/Caches/org.swift.swiftpm"

  echo -e "\n${green}SPM caches cleared."
else
  echo -e "\n${green}Trigger phrase not found. Skipping SPM cache clearing."
fi
