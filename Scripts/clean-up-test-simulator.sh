#!/usr/bin/env bash
#
# Script used with Drone CI to delete the simulator created for the unit tests when the pipline ends.

if [[ -z "$1" ]]; then
	echo -e "\n\n\n\n\e[31;1mSimulator UUID not provided.\e[0m\n\n\n"
	exit 1
fi

SIM_UUID="$1"

function handle_exit() {
	xcrun simctl delete unavailable
	xcrun simctl delete ${SIM_UUID}
	echo -e "\n\n\n\n\e[32mSimulator ${SIM_UUID} deleted.\e[0m\n\n\n"
	exit 0
}

trap handle_exit EXIT

while true; do
	sleep 10
done