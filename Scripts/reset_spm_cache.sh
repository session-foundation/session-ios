#!/usr/bin/env bash

set -e

green="\e[32;1m"

if echo "${DRONE_COMMIT_MESSAGE}" | grep -q -F "[Reset SPM]"; then
  echo "Trigger phrase found in commit message. Clearing SPM caches..."
  
  echo "--> Clearing global SwiftPM repository cache (~/.swiftpm)..."
  rm -rf ~/.swiftpm || echo "Warning: Failed to remove ~/.swiftpm (might not exist or permissions issue)"

  echo "--> Clearing global SwiftPM artifact/registry cache (~/Library/Caches/org.swift.swiftpm)..."
  rm -rf ~/Library/Caches/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/Caches/org.swift.swiftpm (might not exist or permissions issue)"

  echo "--> Clearing global SwiftPM artifact fingerprints (~/Library/org.swift.swiftpm)..."
  rm -rf ~/Library/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/org.swift.swiftpm (might not exist or permissions issue)"

  echo -e "\n${green}SPM caches cleared."
else
  echo -e "\n${green}Trigger phrase not found. Skipping SPM cache clearing."
fi

echo "--- Searching for bad checksum string (f528...) ---"
find /var/folders /tmp ~/Library -type f -exec grep -q 'f528fc9fbc9f' {} \; -print 2>/dev/null | tee find_results_checksum.log
echo "--- Find Results (Checksum) ---"
cat find_results_checksum.log || echo "No checksum results found."
