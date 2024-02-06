#!/usr/bin/env bash

# Script used with Drone CI to check for the existence of a build artifact.

current_dir="$(dirname "$0")"
upload_url=$("${current_dir}/drone-static-upload.sh" false)
upload_dir="$(dirname "${upload_url}")"
target_file_pattern="$(basename "${upload_url}")"

echo "Starting to poll ${upload_dir} every 10s to check for a build matching '${target_file_pattern}'"

# Loop indefinitely the CI can timeout the script if it takes too long
total_poll_duration=0
max_poll_duration=(30 * 60)	# Poll for a maximum of 30 mins

while true; do
	# Need to add the trailing '/' or else we get a '301' response
	build_artifacts_html=$(curl -s "${upload_dir}/")

	if [ $? != 0 ]; then
		echo "Failed to retrieve build artifact list"
		exit 1
	fi

	# Extract 'session-ios...' titles using grep and awk
	current_build_artifacts=$(echo "$build_artifacts_html" | grep -o 'href="session-ios-[^"]*' | sed 's/href="//')

	# Use grep to check for the combination
	target_file=$(echo "$current_build_artifacts" | grep -o "$target_file_pattern" | tail -n 1)

	if [ -n "$target_file" ]; then
		echo -e "\n\n\n\n\e[32;1mExisting build artifact at ${upload_dir}/${target_file}\e[0m\n\n\n"
	    exit 0
	fi

	# Sleep for 10 seconds before checking again
	sleep 10
	total_poll_duration=$((total_poll_duration + 10))

	if [ $total_poll_duration -gt $max_poll_duration ]; then
		echo -e "\n\n\n\n\e[31;1mCould not find existing build artifact after polling for 30 minutes\e[0m\n\n\n"
	fi
done
