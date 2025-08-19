#!/bin/bash

# Need to set the path or we won't find cmake
PATH=${PATH}:/usr/local/bin:/opt/local/bin:/opt/homebrew/bin:/opt/homebrew/opt/m4/bin:/sbin/md5
required_packages=("cmake" "m4" "pkg-config")

# Calculate paths
DERIVED_DATA_PATH=$(echo "${BUILD_DIR}" | sed -E 's#^(.*[dD]erived[Dd]ata)(/[sS]ession-[^/]+)?.*#\1\2#' | tr -d '\n')
PRE_BUILT_FRAMEWORK_DIR="${DERIVED_DATA_PATH}/SourcePackages/artifacts/libsession-util-spm/SessionUtil"
FRAMEWORK_DIR="libsession-util.xcframework"
COMPILE_DIR="${TARGET_BUILD_DIR}/LibSessionUtil"
INDEX_DIR="${DERIVED_DATA_PATH}/Index.noindex/Build/Products/Debug-${PLATFORM_NAME}"
LAST_SUCCESSFUL_HASH_FILE="${TARGET_BUILD_DIR}/last_successful_source_tree.hash.log"
LAST_BUILT_FRAMEWORK_SLICE_DIR_FILE="${TARGET_BUILD_DIR}/last_built_framework_slice_dir.log"
BUILT_LIB_FINAL_TIMESTAMP_FILE="${TARGET_BUILD_DIR}/libsession_util_built.timestamp"

# Save original stdout and set trap for cleanup
exec 3>&1
function finish {
  # Restore stdout
  exec 1>&3 3>&-
}
trap finish EXIT ERR SIGINT SIGTERM

# Determine whether we want to build from source
TARGET_ARCH_DIR=""

if [ -z $PLATFORM_NAME ] || [ $PLATFORM_NAME = "iphonesimulator" ]; then
  TARGET_ARCH_DIR="ios-arm64_x86_64-simulator"
elif [ $PLATFORM_NAME = "iphoneos" ]; then
  TARGET_ARCH_DIR="ios-arm64"
else
  echo "error: Unable to find pre-packaged library for the current platform ($PLATFORM_NAME)."
  exit 1
fi

if [ "${COMPILE_LIB_SESSION}" != "YES" ]; then
  echo "Restoring original headers to Xcode Indexer cache from backup..."
  rm -rf "${INDEX_DIR}/include"
  rsync -rt --exclude='.DS_Store' "${PRE_BUILT_FRAMEWORK_DIR}/${FRAMEWORK_DIR}/${TARGET_ARCH_DIR}/Headers/" "${INDEX_DIR}/include"

  echo "Using pre-packaged SessionUtil"
  exit 0
fi

# Ensure the machine has the build dependencies installed
echo "Validating build requirements: ${required_packages[*]}"
missing_packages=()

for package in "${required_packages[@]}"; do
  if ! which "$package" > /dev/null; then
    missing_packages+=("$package")
  fi
done

if [ ${#missing_packages[@]} -ne 0 ]; then
  packages=$(echo "${missing_packages[@]}")
  echo "error: Missing build dependencies: ${missing_packages[*]}. Please install them (eg. 'brew install ${missing_packages[*]}'):"
  exit 1
fi

# Ensure the source directory is there
echo "LibSession source: ${LIB_SESSION_SOURCE_DIR}"
echo "Build dir: ${COMPILE_DIR}"

echo "- Validating source exists"
if [ -z "${LIB_SESSION_SOURCE_DIR}" ] || [ ! -d "${LIB_SESSION_SOURCE_DIR}" ]; then
  echo "error: LIB_SESSION_SOURCE_DIR is not set or not a directory: '${LIB_SESSION_SOURCE_DIR}'"
  exit 1
fi

# Validate submodules
echo "- Validating submodules"
if ! (cd "${LIB_SESSION_SOURCE_DIR}" && git submodule status --recursive | grep -q '^-'); then
    echo "- Submodules appear to be initialized and updated."
else
    (cd "${LIB_SESSION_SOURCE_DIR}" && git submodule status --recursive) # Show problematic submodules
    echo "error: Submodules in ${LIB_SESSION_SOURCE_DIR} are not initialized or updated. Please run 'git submodule update --init --recursive' there."
    exit 1
fi

# Check the current state of the build (comparing hashes to determine if there was a source change)
echo "- Checking if libSession changed..."
REQUIRES_BUILD=0

# Generate a hash to determine whether any source files have changed
SOURCE_HASH=$(find "${LIB_SESSION_SOURCE_DIR}/src" -type f -not -name '.DS_Store' -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')
HEADER_HASH=$(find "${LIB_SESSION_SOURCE_DIR}/include" -type f -not -name '.DS_Store' -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')
EXTERNAL_HASH=$(find "${LIB_SESSION_SOURCE_DIR}/external" -type f -not -name '.DS_Store' -exec md5 {} + | awk '{print $NF}' | sort | md5 | awk '{print $NF}')
MAKE_LISTS_HASH=$(md5 -q "${LIB_SESSION_SOURCE_DIR}/CMakeLists.txt")
STATIC_BUNDLE_HASH=$(md5 -q "${LIB_SESSION_SOURCE_DIR}/utils/static-bundle.sh")

CURRENT_SOURCE_TREE_HASH=$( (
  echo "${SOURCE_HASH}"
  echo "${HEADER_HASH}"
  echo "${EXTERNAL_HASH}"
  echo "${MAKE_LISTS_HASH}"
  echo "${STATIC_BUNDLE_HASH}"
) | sort | md5 -q)

PREVIOUS_BUILT_FRAMEWORK_SLICE_DIR=""
if [ -f "$LAST_BUILT_FRAMEWORK_SLICE_DIR_FILE" ]; then
  read -r PREVIOUS_BUILT_FRAMEWORK_SLICE_DIR < "$LAST_BUILT_FRAMEWORK_SLICE_DIR_FILE"
fi

PREVIOUS_BUILT_HASH=""
if [ -f "$LAST_SUCCESSFUL_HASH_FILE" ]; then
  read -r PREVIOUS_BUILT_HASH < "$LAST_SUCCESSFUL_HASH_FILE"
fi

# Ensure the build directory exists (in case we need it before XCode creates it)
mkdir -p "${COMPILE_DIR}"

if [ "${CURRENT_SOURCE_TREE_HASH}" != "${PREVIOUS_BUILT_HASH}" ]; then
  echo "- Build is not up-to-date (source change) - creating new build"
  REQUIRES_BUILD=1
elif [ "${TARGET_ARCH_DIR}" != "${PREVIOUS_BUILT_FRAMEWORK_SLICE_DIR}" ]; then
  echo "- Build is not up-to-date (build architectures changed) - creating new build"
  REQUIRES_BUILD=1
elif [ ! -f "${COMPILE_DIR}/libsession-util.a" ]; then
  echo "- Build is not up-to-date (no static lib) - creating new build"
  REQUIRES_BUILD=1
else
  echo "- Build is up-to-date"
fi

if [ "${REQUIRES_BUILD}" == 1 ]; then
  # Import settings from XCode (defaulting values if not present)
  VALID_SIM_ARCHS=(arm64 x86_64)
  VALID_DEVICE_ARCHS=(arm64)
  VALID_SIM_ARCH_PLATFORMS=(SIMULATORARM64 SIMULATOR64)
  VALID_DEVICE_ARCH_PLATFORMS=(OS64)

  OUTPUT_DIR="${TARGET_BUILD_DIR}"
  IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET}
  ENABLE_BITCODE=${ENABLE_BITCODE}

  # Generate the target architectures we want to build for
  TARGET_ARCHS=()
  TARGET_PLATFORMS=()
  TARGET_SIM_ARCHS=()
  TARGET_DEVICE_ARCHS=()

  if [ -z $PLATFORM_NAME ] || [ $PLATFORM_NAME = "iphonesimulator" ]; then
    for i in "${!VALID_SIM_ARCHS[@]}"; do
      ARCH="${VALID_SIM_ARCHS[$i]}"
      ARCH_PLATFORM="${VALID_SIM_ARCH_PLATFORMS[$i]}"

      if [[ " ${ARCHS[*]} " =~ " ${ARCH} " ]]; then
        TARGET_ARCHS+=("sim-${ARCH}")
        TARGET_PLATFORMS+=("${ARCH_PLATFORM}")
        TARGET_SIM_ARCHS+=("sim-${ARCH}")
      fi
    done
  fi

  if [ -z $PLATFORM_NAME ] || [ $PLATFORM_NAME = "iphoneos" ]; then
    for i in "${!VALID_DEVICE_ARCHS[@]}"; do
      ARCH="${VALID_DEVICE_ARCHS[$i]}"
      ARCH_PLATFORM="${VALID_DEVICE_ARCH_PLATFORMS[$i]}"

      if [[ " ${ARCHS[*]} " =~ " ${ARCH} " ]]; then
        TARGET_ARCHS+=("ios-${ARCH}")
        TARGET_PLATFORMS+=("${ARCH_PLATFORM}")
        TARGET_DEVICE_ARCHS+=("ios-${ARCH}")
      fi
    done
  fi

  # Remove any old build logs (since we are doing a new build)
  rm -rf "${COMPILE_DIR}/libsession_util_output.log"
  touch "${COMPILE_DIR}/libsession_util_output.log"

  submodule_check=ON
  build_type="Release"

  if [ "$CONFIGURATION" == "Debug" ] || [ "$CONFIGURATION" == "Debug_Compile_LibSession" ]; then
    submodule_check=OFF
    build_type="Debug"
  fi
  
  # Remove old header files
  rm -rf "${COMPILE_DIR}/Headers"
  
  # Copy the headers across first (if the build fails we still want these so we get less issues
  # with Xcode's autocomplete)
  mkdir -p "${COMPILE_DIR}/Headers"
  cp -r "${LIB_SESSION_SOURCE_DIR}/include/session" "${COMPILE_DIR}/Headers"

  echo "- Generating modulemap for SPM artifact slice"
  modmap_path="${COMPILE_DIR}/Headers/module.modulemap"
  echo "module SessionUtil {" >"$modmap_path"
  echo "  module capi {" >>"$modmap_path"
  for x in $(cd "${COMPILE_DIR}/Headers" && find session -name '*.h'); do
  echo "    header \"$x\"" >>"$modmap_path"
  done
  echo -e "    export *\n  }" >>"$modmap_path"
  echo "}" >>"$modmap_path"

  # Build the individual architectures
  for i in "${!TARGET_ARCHS[@]}"; do
    build="${COMPILE_DIR}/${TARGET_ARCHS[$i]}"
    platform="${TARGET_PLATFORMS[$i]}"
    log_file="${COMPILE_DIR}/libsession_util_output.log"
    echo "- Building ${TARGET_ARCHS[$i]} for $platform in $build"
    
    # Redirect the build output to a log file and only include the progress lines in the XCode output
    exec > >(tee "$log_file" | grep --line-buffered '^\[.*%\]') 2>&1

    cd "${LIB_SESSION_SOURCE_DIR}"
    env -i PATH="$PATH" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
      ./utils/static-bundle.sh "$build" "" \
      -DCMAKE_TOOLCHAIN_FILE="${LIB_SESSION_SOURCE_DIR}/external/ios-cmake/ios.toolchain.cmake" \
      -DPLATFORM=$platform \
      -DDEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET \
      -DENABLE_BITCODE=$ENABLE_BITCODE \
      -DBUILD_TESTS=OFF \
      -DBUILD_STATIC_DEPS=ON \
      -DENABLE_VISIBILITY=ON \
      -DSUBMODULE_CHECK=$submodule_check \
      -DCMAKE_BUILD_TYPE=$build_type \
      -DLOCAL_MIRROR=https://oxen.rocks/deps

    # Capture the exit status of the ./utils/static-bundle.sh command
    EXIT_STATUS=$?
        
    # Flush the tee buffer (ensure any errors have been properly written to the log before continuing) and
    # restore stdout
    echo ""
    exec 1>&3

    # Retrieve and log any submodule errors/warnings
    ALL_CMAKE_ERROR_LINES=($(grep -nE "CMake Error" "$log_file" | cut -d ":" -f 1))
    ALL_SUBMODULE_ISSUE_LINES=($(grep -nE "\s*Submodule '([^']+)' is not up-to-date" "$log_file" | cut -d ":" -f 1))
    ALL_CMAKE_ERROR_LINES_STR=" ${ALL_CMAKE_ERROR_LINES[*]} "
    ALL_SUBMODULE_ISSUE_LINES_STR=" ${ALL_SUBMODULE_ISSUE_LINES[*]} "

    for i in "${!ALL_SUBMODULE_ISSUE_LINES[@]}"; do
      line="${ALL_SUBMODULE_ISSUE_LINES[$i]}"
      prev_line=$((line - 1))
      value=$(sed "${line}q;d" "$log_file" | sed -E "s/.*Submodule '([^']+)'.*/Submodule '\1' is not up-to-date./")
      
      if [[ "$ALL_CMAKE_ERROR_LINES_STR" == *" $prev_line "* ]]; then
        echo "error: $value"
      else
        echo "warning: $value"
      fi
    done

    if [ $EXIT_STATUS -ne 0 ]; then
      ALL_ERROR_LINES=($(grep -n "error:" "$log_file" | cut -d ":" -f 1))

      # Log any other errors
      for e in "${!ALL_ERROR_LINES[@]}"; do
        error_line="${ALL_ERROR_LINES[$e]}"
        error=$(sed "${error_line}q;d" "$log_file")

        # If it was a CMake Error then the actual error will be on the next line so we want to append that info
        if [[ $error == *'CMake Error'* ]]; then
            actual_error_line=$((error_line + 1))
            error="${error}$(sed "${actual_error_line}q;d" "$log_file")"
        fi

        # Exclude the 'ALL_ERROR_LINES' line and the 'grep' line
        if [[ ! $error == *'grep -n "error'* ]] && [[ ! $error == *'grep -n error'* ]]; then
            echo "error: $error"
        fi
      done
      
      # If the build failed we still want to copy files across because it'll help errors appear correctly
      echo "- Replacing build dir files"

      # Remove the current files (might be "newer")
      rm -rf "${TARGET_BUILD_DIR}/libsession-util.a"
      rm -rf "${TARGET_BUILD_DIR}/include"
      rm -rf "${INDEX_DIR}/include"

      # Rsync the compiled ones (maintaining timestamps)
      rsync -rt "${COMPILE_DIR}/libsession-util.a" "${TARGET_BUILD_DIR}/libsession-util.a"
      rsync -rt --exclude='.DS_Store' "${COMPILE_DIR}/Headers/" "${TARGET_BUILD_DIR}/include"
      rsync -rt --exclude='.DS_Store' "${COMPILE_DIR}/Headers/" "${INDEX_DIR}/include"
      exit 1
    fi
  done

  # Remove the old static library file
  rm -rf "${COMPILE_DIR}/libsession-util.a"

  # If needed combine simulator builds into a multi-arch lib
  if [ "${#TARGET_SIM_ARCHS[@]}" -eq "1" ]; then
    # Single device build
    cp "${COMPILE_DIR}/${TARGET_SIM_ARCHS[0]}/libsession-util.a" "${COMPILE_DIR}/libsession-util.a"
  elif [ "${#TARGET_SIM_ARCHS[@]}" -gt "1" ]; then
    # Combine multiple device builds into a multi-arch lib
    echo "Built multiple architectures, merging into single static library"
    lipo -create "${COMPILE_DIR}"/sim-*/libsession-util.a -output "${COMPILE_DIR}/libsession-util.a"
  fi

  # If needed combine device builds into a multi-arch lib
  if [ "${#TARGET_DEVICE_ARCHS[@]}" -eq "1" ]; then
    cp "${COMPILE_DIR}/${TARGET_DEVICE_ARCHS[0]}/libsession-util.a" "${COMPILE_DIR}/libsession-util.a"
  elif [ "${#TARGET_DEVICE_ARCHS[@]}" -gt "1" ]; then
    # Combine multiple device builds into a multi-arch lib
    echo "Built multiple architectures, merging into single static library"
    lipo -create "${COMPILE_DIR}"/ios-*/libsession-util.a -output "${COMPILE_DIR}/libsession-util.a"
  fi
  
  echo "- Saving successful build cache files"
  echo "${TARGET_ARCH_DIR}" > "${LAST_BUILT_FRAMEWORK_SLICE_DIR_FILE}"
  echo "${CURRENT_SOURCE_TREE_HASH}" > "${LAST_SUCCESSFUL_HASH_FILE}"
  
  echo "- Touching timestamp file to signal update to Xcode"
  touch "${BUILT_LIB_FINAL_TIMESTAMP_FILE}"
  cp "${BUILT_LIB_FINAL_TIMESTAMP_FILE}" "${SPM_TIMESTAMP_FILE}"

  echo "- Build complete"
fi

echo "- Replacing build dir files"

# Remove the current files (might be "newer")
rm -rf "${TARGET_BUILD_DIR}/libsession-util.a"
rm -rf "${TARGET_BUILD_DIR}/include"
rm -rf "${INDEX_DIR}/include"

# Rsync the compiled ones (maintaining timestamps)
rsync -rt "${COMPILE_DIR}/libsession-util.a" "${TARGET_BUILD_DIR}/libsession-util.a"
rsync -rt --exclude='.DS_Store' "${COMPILE_DIR}/Headers/" "${TARGET_BUILD_DIR}/include"
rsync -rt --exclude='.DS_Store' "${COMPILE_DIR}/Headers/" "${INDEX_DIR}/include"

# Output to XCode just so the output is good
echo "LibSession is Ready"
