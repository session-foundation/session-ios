#!/bin/bash

# XCode will error during it's dependency graph construction (which happens before the build
# stage starts and any target "Run Script" phases are triggered)
#
# In order to avoid this error we need to build the framework before actually getting to the
# build stage so XCode is able to build the dependency graph
#
# XCode's Pre-action scripts don't output anything into XCode so the only way to emit a useful
# error is to return a success status and have the project detect and log the error itself then
# log it, stopping the build at that point
#
# The other step to get this to work properly is to ensure the framework in "Link Binary with
# Libraries" isn't using a relative directory, unfortunately there doesn't seem to be a good
# way to do this directly so we need to modify the '.pbxproj' file directly, updating the
# framework entry to have the following (on a single line):
# {
#   isa = PBXFileReference;
#   explicitFileType = wrapper.xcframework;
#   includeInIndex = 0;
#   path = "{FRAMEWORK NAME GOES HERE}";
#   sourceTree = BUILD_DIR;
# };

# Need to set the path or we won't find cmake
PATH=${PATH}:/usr/local/bin:/opt/homebrew/bin:/sbin/md5

# Ensure the build directory exists (in case we need it before XCode creates it)
mkdir -p "${TARGET_BUILD_DIR}"

# Remove any old build errors
rm -rf "${TARGET_BUILD_DIR}/libsession_util_error.log"

# First ensure cmake is installed (store the error in a log and exit with a success status - xcode will output the error)
echo "info: Validating build requirements"

if ! which cmake > /dev/null; then
  touch "${TARGET_BUILD_DIR}/libsession_util_error.log"
  echo "error: cmake is required to build, please install (can install via homebrew with 'brew install cmake')."
  echo "error: cmake is required to build, please install (can install via homebrew with 'brew install cmake')." > "${TARGET_BUILD_DIR}/libsession_util_error.log"
  exit 0
fi

if [ ! -d "${SRCROOT}/LibSession-Util" ] || [ ! -d "${SRCROOT}/LibSession-Util/src" ]; then
  touch "${TARGET_BUILD_DIR}/libsession_util_error.log"
  echo "error: Need to fetch LibSession-Util submodule."
  echo "error: Need to fetch LibSession-Util submodule." > "${TARGET_BUILD_DIR}/libsession_util_error.log"
  exit 1
fi

# Generate a hash of the libSession-util source files and check if they differ from the last hash
echo "info: Checking for changes to source"

NEW_SOURCE_HASH=$(find "${SRCROOT}/LibSession-Util/src" -type f -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')
NEW_HEADER_HASH=$(find "${SRCROOT}/LibSession-Util/include" -type f -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')

if [ -f "${TARGET_BUILD_DIR}/libsession_util_source_hash.log" ]; then
    read -r OLD_SOURCE_HASH < "${TARGET_BUILD_DIR}/libsession_util_source_hash.log"
fi

if [ -f "${TARGET_BUILD_DIR}/libsession_util_header_hash.log" ]; then
    read -r OLD_HEADER_HASH < "${TARGET_BUILD_DIR}/libsession_util_header_hash.log"
fi

if [ -f "${TARGET_BUILD_DIR}/libsession_util_archs.log" ]; then
    read -r OLD_ARCHS < "${TARGET_BUILD_DIR}/libsession_util_archs.log"
fi

# Start the libSession-util build if it doesn't already exists
if [ "${NEW_SOURCE_HASH}" != "${OLD_SOURCE_HASH}" ] || [ "${NEW_HEADER_HASH}" != "${OLD_HEADER_HASH}" ] || [ "${ARCHS[*]}" != "${OLD_ARCHS}" ] || [ ! -d "${TARGET_BUILD_DIR}/libsession-util.xcframework" ]; then
  echo "info: Build is not up-to-date - creating new build"
  echo ""

  # Remove any existing build files (just to be safe)
  rm -rf "${TARGET_BUILD_DIR}/libsession-util.a"
  rm -rf "${TARGET_BUILD_DIR}/libsession-util.xcframework"
  rm -rf "${BUILD_DIR}/libsession-util.xcframework"

  # Trigger the new build
  cd "${SRCROOT}/LibSession-Util"
  result=$(./utils/ios.sh "libsession-util" false)

  if [ $? -ne 0 ]; then
    touch "${TARGET_BUILD_DIR}/libsession_util_error.log"
    echo "error: Failed to build libsession-util (See details in '${TARGET_BUILD_DIR}/pre-action-output.log')."
    echo "error: Failed to build libsession-util (See details in '${TARGET_BUILD_DIR}/pre-action-output.log')." > "${TARGET_BUILD_DIR}/libsession_util_error.log"
    exit 0
  fi

  # Save the updated source hash to disk to prevent rebuilds when there were no changes
  echo "${NEW_SOURCE_HASH}" > "${TARGET_BUILD_DIR}/libsession_util_source_hash.log"
  echo "${NEW_HEADER_HASH}" > "${TARGET_BUILD_DIR}/libsession_util_header_hash.log"
  echo "${ARCHS[*]}" > "${TARGET_BUILD_DIR}/libsession_util_archs.log"
  echo ""
  echo "info: Build complete"
else
  echo "info: Build is up-to-date"
fi

# Move the target-specific libSession-util build to the parent build directory (so XCode can have a reference to a single build)
rm -rf "${BUILD_DIR}/libsession-util.xcframework"
cp -r "${TARGET_BUILD_DIR}/libsession-util.xcframework" "${BUILD_DIR}/libsession-util.xcframework"
