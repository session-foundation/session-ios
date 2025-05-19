#!/usr/bin/env bash
#
# Script used with Drone CI to delete any test simulators created by the pipeline that are older than 1
# hour (the timeout for iOS builds) to ensure we don't waste too much HDD space with test simulators

set -euo pipefail

SIMULATOR_DEVICE_PATH_ROOT="$HOME/Library/Developer/CoreSimulator/Devices"
MAX_AGE_MINUTES=60 # Simulators older than this will be targeted
TRIGGER_PHRASE="[Clear Simulators]"
reset="\e[0m"
red="\e[31;1m"
green="\e[32;1m"
yellow="\e[33;1m"
blue="\e[34;1m"
cyan="\e[36;1m"

if ! echo "${DRONE_COMMIT_MESSAGE:-}" | grep -q -F "$TRIGGER_PHRASE"; then
  echo -e "\n${green}Trigger phrase '$TRIGGER_PHRASE' not found in commit message. Skipping old simulator cleanup.${reset}"
  exit 0
else
  echo "\n${cyan}Trigger phrase found. Cleaning up old simulators...${reset}"
fi

# The $HOME directory for a drone pipeline won't be the directory the simulators are stored in so
# check if it exists and if not, fallback to a hard-coded directory
if [[ ! -d "$SIMULATOR_DEVICE_PATH_ROOT" ]]; then
  echo -e "${yellow}Default simulator path $SIMULATOR_DEVICE_PATH_ROOT not found. Trying fallback...${reset}"
  SIMULATOR_DEVICE_PATH_ROOT="/Users/drone/Library/Developer/CoreSimulator/Devices"
  if [[ ! -d "$SIMULATOR_DEVICE_PATH_ROOT" ]]; then
    echo -e "${red}Simulator device path $SIMULATOR_DEVICE_PATH_ROOT not found. Cannot proceed.${reset}"
    exit 1
  fi
fi
echo -e "${cyan}Using simulator device path: $SIMULATOR_DEVICE_PATH_ROOT${reset}"

# Plist file
DEVICE_SET_PLIST="${SIMULATOR_DEVICE_PATH_ROOT}/device_set.plist"

if [[ ! -f ${DEVICE_SET_PLIST} ]]; then
	echo -e "\n${red}XCode Simulator list ($DEVICE_SET_PLIST) not found. This might indicate an issue with the simulator environment.${reset}"
	exit 1
fi

# Delete any unavailable simulators
echo -e "\n${cyan}Attempting to delete any 'unavailable' simulators via simctl...${reset}"
if ! xcrun simctl delete unavailable; then
    echo -e "${yellow}Warning: 'xcrun simctl delete unavailable' failed. Continuing, but some simulators might not be cleaned properly.${reset}"
fi

# Extract all UUIDs from the device_set
echo -e "\n${cyan}Gathering list of simulators from simctl...${reset}"
mapfile -t simctl_known_uuids < <(xcrun simctl list devices -j | jq -r '.devices | to_entries[] | .value[]? | .udid // empty' || true)

if [ ${#simctl_known_uuids[@]} -eq 0 ]; then
    echo -e "${yellow}No simulators are currently registered with simctl.${reset}"
fi

# Create empty arrays to store the outputs
declare -a uuids_to_delete_via_simctl=()
declare -a uuids_to_keep_active=()
declare -a paths_of_old_orphaned_dirs=()
declare -A processed_disk_uuids

echo -e "\n${cyan}Analyzing simulator directories in $SIMULATOR_DEVICE_PATH_ROOT...${reset}"

# Process simulators known to simctl
for uuid in "${simctl_known_uuids[@]}"; do
  sim_data_path="${SIMULATOR_DEVICE_PATH_ROOT}/${uuid}"
  processed_disk_uuids["$uuid"]=1 # Mark as processed

  if [ ! -d "$sim_data_path" ]; then
    echo -e "${yellow}  Simulator $uuid is known to simctl but its directory $sim_data_path is missing. It might have been removed by 'delete unavailable' or is malformed.${reset}"
    continue
  fi

  # Check modification time of the directory itself
  # Using -mmin "+${MAX_AGE_MINUTES}" means older than MAX_AGE_MINUTES (e.g., +60 means 61 minutes or older)
  if find "$sim_data_path" -maxdepth 0 -type d -mmin "+$((MAX_AGE_MINUTES -1))" -print -quit | grep -q .; then
    echo -e "${yellow}  Found old, registered simulator: $uuid (Path: $sim_data_path)${reset}"
    uuids_to_delete_via_simctl+=("$uuid")
  else
    uuids_to_keep_active+=("$uuid")
  fi
done

# Find orphaned directories (exist on disk, are old, but not known to simctl)
# Iterate over all directory names in SIMULATOR_DEVICE_PATH_ROOT that look like UUIDs
mapfile -t all_disk_uuid_dirs < <(find "$SIMULATOR_DEVICE_PATH_ROOT" -maxdepth 1 -type d -not -path "$SIMULATOR_DEVICE_PATH_ROOT" -exec basename {} \; 2>/dev/null | grep -E '^[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}$' || true)

for disk_uuid in "${all_disk_uuid_dirs[@]}"; do
  if [[ -n "${processed_disk_uuids[$disk_uuid]:-}" ]]; then
    continue # Already processed (was known to simctl)
  fi

  sim_data_path="${SIMULATOR_DEVICE_PATH_ROOT}/${disk_uuid}"
  
  if find "$sim_data_path" -maxdepth 0 -type d -mmin "+$((MAX_AGE_MINUTES-1))" -print -quit | grep -q .; then
    echo -e "${yellow}  Found old, orphaned simulator directory: $disk_uuid (Path: $sim_data_path)${reset}"
    paths_of_old_orphaned_dirs+=("$sim_data_path")
  else
    echo -e "${yellow}  Found new, orphaned simulator directory (leaving untouched): $disk_uuid (Path: $sim_data_path)${reset}"
  fi
done

# Delete the simulators
deleted_count=0
failed_simctl_delete_count=0

if [ ${#uuids_to_delete_via_simctl[@]} -gt 0 ]; then
  echo -e "\n${red}Deleting ${#uuids_to_delete_via_simctl[@]} old, registered simulators via simctl:${reset}"
  for uuid in "${uuids_to_delete_via_simctl[@]}"; do
    echo -e "${red}  Attempting to delete simulator: $uuid${reset}"
    if xcrun simctl delete "$uuid"; then
      echo -e "${green}    Successfully deleted $uuid${reset}"
      deleted_count=$((deleted_count + 1))
    else
      echo -e "${yellow}    Failed to delete $uuid via simctl. It might have been removed already or is in a problematic state.${reset}"
      failed_simctl_delete_count=$((failed_simctl_delete_count + 1))
    fi
  done
else
  echo -e "\n${green}No old, registered simulators found to delete via simctl.${reset}"
fi

removed_dir_count=0
failed_rm_count=0
if [ ${#paths_of_old_orphaned_dirs[@]} -gt 0 ]; then
  echo -e "\n${red}Deleting ${#paths_of_old_orphaned_dirs[@]} old, orphaned simulator directories from disk:${reset}"
  for dir_path in "${paths_of_old_orphaned_dirs[@]}"; do
    echo -e "${red}  Attempting to delete directory: $dir_path${reset}"
    if rm -rf "$dir_path"; then
      echo -e "${green}    Successfully deleted $dir_path${reset}"
      removed_dir_count=$((removed_dir_count + 1))
    else
      # This should be rare with sudo, but good to catch.
      echo -e "${yellow}    Failed to delete directory $dir_path. Check permissions or if it's unexpectedly in use.${reset}"
      failed_rm_count=$((failed_rm_count + 1))
    fi
  done
else
  echo -e "\n${green}No old, orphaned simulator directories found to remove from disk.${reset}"
fi

# Output the simulators we are keeping
if [ ${#uuids_to_keep_active[@]} -gt 0 ]; then
  echo -e "\n${yellow}Keeping ${#uuids_to_keep_active[@]} simulators (likely active, new, or explicitly not targeted):${reset}"
  for uuid in "${uuids_to_keep_active[@]}"; do
    echo -e "${yellow}  $uuid${reset}"
  done
else
  echo -e "\n${green}No active/new simulators identified to explicitly keep (beyond non-orphaned new ones).${reset}"
fi


# Summary
echo -e "\n${cyan}--- Cleanup Summary ---${reset}"
echo -e "${green}Simulators deleted via simctl: $deleted_count${reset}"
if [ $failed_simctl_delete_count -gt 0 ]; then
  echo -e "${yellow}Simulators failed to delete via simctl: $failed_simctl_delete_count${reset}"
fi
echo -e "${green}Orphaned directories removed: $removed_dir_count${reset}"
if [ $failed_rm_count -gt 0 ]; then
  echo -e "${yellow}Orphaned directories failed to remove: $failed_rm_count${reset}"
fi
echo -e "${green}Active/new simulators kept: ${#uuids_to_keep_active[@]}${reset}"
echo -e "\n${green}Old simulators cleanup process finished.${reset}"
