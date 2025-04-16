#!/usr/bin/env bash

set -e

green="\e[32;1m"

if echo "${DRONE_COMMIT_MESSAGE}" | grep -q -F "[Reset SPM]"; then
  echo "Trigger phrase found in commit message. Clearing SPM caches..."
  
  echo "--> Clearing global SwiftPM repository cache (~/.swiftpm/repositories)..."
  rm -rf ~/.swiftpm/repositories || echo "Warning: Failed to remove ~/.swiftpm/repositories (might not exist or permissions issue)"

  echo "--> Clearing global SwiftPM artifact/registry cache (~/Library/Caches/org.swift.swiftpm)..."
  rm -rf ~/Library/Caches/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/Caches/org.swift.swiftpm (might not exist or permissions issue)"

  echo "--> Clearing global SwiftPM artifact fingerprints (~/Library/org.swift.swiftpm)..."
  rm -rf ~/Library/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/org.swift.swiftpm (might not exist or permissions issue)"
  
  echo -e "\n${green}SPM caches cleared."
else
  echo -e "\n${green}Trigger phrase not found. Skipping SPM cache clearing."
fi
