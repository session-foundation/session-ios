#!/usr/bin/env bash
#
# Script used with Drone CI to delete any test simulators created by the pipeline that are older than 1
# hour (the timeout for iOS builds) to ensure we don't waste too much HDD space with test simulators.

dir="$HOME/Library/Developer/CoreSimulator/Devices"

# The $HOME directory for a drone pipeline won't be the directory the simulators are stored in so
# check if it exists and if not, fallback to a hard-coded directory
if [[ ! -d $dir ]]; then
  dir="/Users/drone/Library/Developer/CoreSimulator/Devices"
  ls $dir
  cat "${dir}/device_set.plist"
fi

# Plist file
plist="${dir}/device_set.plist"

if [[ ! -f ${plist} ]]; then
	echo -e "\e[31;1mXCode Simulator list not found.\e[0m"
	exit 1
fi

# Delete any unavailable simulators
xcrun simctl delete unavailable

# Extract all UUIDs from the device_set
uuids=$(grep -Eo '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' "$plist")
running_uuids=$(xcrun simctl list devices | grep -Eo '[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}' | grep -v 'Shutdown')

# Create empty arrays to store the outputs
uuids_to_leave=()
uuids_to_remove=()

# Find directories older than an hour
while read -r dir; do
  # Get the last component of the directory path
  dir_name=$(basename "$dir")

  # Check if the directory name is in the list of UUIDs
  if ! echo "$uuids" | grep -q "$dir_name"; then
    uuids_to_remove+=("$dir_name")
  else
    uuids_to_leave+=("$dir_name")
  fi
done < <(find "$dir" -maxdepth 1 -type d -not -path "$dir" -mmin +60)

# Delete the simulators
if [ ${#uuids_to_remove[@]} -eq 0 ]; then
  echo -e "\e[31mNo simulators to delete\e[0m"
else
  echo -e "\e[31mDeleting ${#uuids_to_remove[@]} old test simulators:\e[0m"
  for uuid in "${uuids_to_remove[@]}"; do
    echo -e "\e[31m    $uuid\e[0m"
    xcrun simctl delete "$uuid"
  done
fi

# Output the pipeline simulators we are leaving
uuids_to_keep=$(echo "$uuids" | grep -v "${uuids_to_leave[*]}" | grep -v "${uuids_to_remove[*]}")
if [ ${#uuids_to_keep[@]} -gt 0 ]; then
  echo -e "\e[33m\nIgnoring ${#uuids_to_keep[@]} test simulators (might be in use):\e[0m"
  for uuid in "${uuids_to_keep[@]}"; do
  	echo -e "\e[33m    $uuid\e[0m"
  done
fi

# Output the remaining Xcode Simulators
echo -e "\e[32m\nIgnoring ${#uuids_to_leave[@]} Xcode simulators:\e[0m"
for uuid in "${uuids_to_leave[@]}"; do
  echo -e "\e[32m    $uuid\e[0m"
done