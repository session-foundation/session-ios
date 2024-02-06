#!/usr/bin/env bash

# Script used with Drone CI to check for the existence of a build artifact.

current_dir="$(dirname "$0")"
upload_url=$("${current_dir}/drone-static-upload.sh" false)
upload_dir="$(dirname "${upload_url}")"
target_file_pattern="$(basename "${upload_url}")"

# Loop indefinitely the CI can timeout the script if it takes too long
while true; do
	# Need to add the trailing '/' or else we get a '301' response
	build_artifacts_html=$(curl -X GET "${upload_dir}/")

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
done
