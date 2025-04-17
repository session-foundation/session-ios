#!/usr/bin/env bash

set -e

green="\e[32;1m"

if echo "${DRONE_COMMIT_MESSAGE}" | grep -q -F "[Reset SPM]"; then
  echo "Trigger phrase found in commit message. Clearing SPM caches..."
  
  echo "--> Clearing global SwiftPM caches..."
  rm -rf ~/.swiftpm || echo "Warning: Failed to remove ~/.swiftpm"
  rm -rf ~/Library/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/org.swift.swiftpm"
  rm -rf ~/Library/Caches/org.swift.swiftpm || echo "Warning: Failed to remove ~/Library/Caches/org.swift.swiftpm"
  rm -rf ~/Library/Caches/org.swift.swiftpm/repositories || echo "Warning: Failed to remove ~/Library/Caches/org.swift.swiftpm/repositories"
  rm -rf ~/Library/Caches/com.apple.dt.Xcode || echo "Warning: Failed to remove ~/Library/Caches/com.apple.dt.Xcode"
  rm -rf /var/folders/*/*/*/com.apple.DeveloperTools/*/Xcode/SourcePackages
  

  echo "--> Removing project build directories (just in case)..."
  rm -rf ~/Library/Developer/Xcode/DerivedData || echo "Warning: Failed to remove ~/Library/Developer/Xcode/DerivedData"

  echo "--> Clearing Drone-specific caches..."
  rm -rf /drone/src/DerivedData || echo "Warning: Failed to remove /drone/src/DerivedData"
  rm -rf /drone/src/.build || echo "Warning: Failed to remove /drone/src/.build"
  rm -rf /drone/src/.swiftpm || echo "Warning: Failed to remove /drone/src/.swiftpm"

  echo -e "\n${green}SPM caches cleared."
else
  echo -e "\n${green}Trigger phrase not found. Skipping SPM cache clearing."
fi

echo "--> Finding and removing ALL Swift PM cache locations..."
find / -name "*SessionUtil*" -type f 2>/dev/null | xargs rm -f 2>/dev/null || true
find / -path "*/swiftpm*" -type d 2>/dev/null | xargs rm -rf 2>/dev/null || true
find / -name "*.fingerprint" -type f 2>/dev/null | xargs grep -l "SessionUtil" | xargs rm -f 2>/dev/null || true

