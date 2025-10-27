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

# Robustly removes a directory, first clearing any immutable flags (work around Xcode's indexer file locking)
remove_locked_dir() {
  local dir_to_remove="$1"
  if [ -d "${dir_to_remove}" ]; then
    echo "- Unlocking and removing ${dir_to_remove}"
    chflags -R nouchg "${dir_to_remove}" &>/dev/null || true
    rm -rf "${dir_to_remove}"
  fi
}

sync_headers() {
    local source_dir="$1"
    echo "- Syncing headers from ${source_dir}"
    
    local destinations=(
        "${TARGET_BUILD_DIR}/include"
        "${INDEX_DIR}/include"
        "${BUILT_PRODUCTS_DIR}/include"
        "${CONFIGURATION_BUILD_DIR}/include"
    )
    
    for dest in "${destinations[@]}"; do
        if [ -n "$dest" ]; then
            remove_locked_dir "$dest"
            mkdir -p "$dest"
            rsync -rtc --delete --exclude='.DS_Store' "${source_dir}/" "$dest/"
            echo "  Synced to: $dest"
        fi
    done
}

# Modify the platform detection to handle archive builds
if [ "${ACTION}" = "install" ] || [ "${CONFIGURATION}" = "Release" ]; then
  # Archive builds typically use 'install' action
  if [ -z "$PLATFORM_NAME" ]; then
    # During archive, PLATFORM_NAME might not be set correctly
    # Default to device build for archives
    PLATFORM_NAME="iphoneos"
    echo "Missing 'PLATFORM_NAME' value, manually set to ${PLATFORM_NAME}"
  fi
fi

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
  echo "Using pre-packaged SessionUtil"
  sync_headers "${PRE_BUILT_FRAMEWORK_DIR}/${FRAMEWORK_DIR}/${TARGET_ARCH_DIR}/Headers/"
  
  # Create the placeholder in the FINAL products directory to satisfy dependency.
  touch "${BUILT_PRODUCTS_DIR}/libsession-util.a"
  
  echo "- Revert to SPM complete."
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

# Generate a hash to determine whether any source files have changed (by using git we automatically
# respect .gitignore)
CURRENT_SOURCE_TREE_HASH=$( \
  ( \
    cd "${LIB_SESSION_SOURCE_DIR}" && git ls-files --recurse-submodules \
  ) \
  | grep -vE '/(tests?|docs?|examples?)/|\.md$|/(\.DS_Store|\.gitignore)$' \
  | sort \
  | tr '\n' '\0' \
  | ( \
      cd "${LIB_SESSION_SOURCE_DIR}" && xargs -0 md5 -r \
    ) \
  | awk '{print $1}' \
  | sort \
  | md5 -q \
)

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
    
    cd "${LIB_SESSION_SOURCE_DIR}"
    {
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
    } 2>&1 | tee "$log_file" | grep --line-buffered -E '^\[.*%\]|:[0-9]+:[0-9]+: error:|^make.*\*\*\*|^error:|^CMake Error'

    # Capture the exit status of the ./utils/static-bundle.sh command
    EXIT_STATUS=${PIPESTATUS[0]}
    
    if [ $EXIT_STATUS -ne 0 ]; then
      # Extract and display CMake/make errors from the log in Xcode error format
      grep -E '^CMake Error' "$log_file" | sort -u | while IFS= read -r line; do
        echo "error: $line"
      done
  
      # If the build failed we still want to copy files across because it'll help errors appear correctly
      echo "- Replacing build dir files"

      # Remove the current files (might be "newer")
      rm -rf "${TARGET_BUILD_DIR}/libsession-util.a"
      rm -rf "${TARGET_BUILD_DIR}/include"
      rm -rf "${INDEX_DIR}/include"

      # Rsync the compiled ones (maintaining timestamps)
      if [ -f "${COMPILE_DIR}/libsession-util.a" ]; then
        rsync -rt "${COMPILE_DIR}/libsession-util.a" "${TARGET_BUILD_DIR}/libsession-util.a"
      fi
      
      if [ -d "${COMPILE_DIR}/Headers" ]; then
        sync_headers "${COMPILE_DIR}/Headers/"
      fi
      
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
  
  echo "- Build complete"
fi

echo "- Replacing build dir files"

# Rsync the compiled ones (maintaining timestamps)
rm -rf "${TARGET_BUILD_DIR}/libsession-util.a"
rsync -rt "${COMPILE_DIR}/libsession-util.a" "${TARGET_BUILD_DIR}/libsession-util.a"

if [ "${TARGET_BUILD_DIR}" != "${BUILT_PRODUCTS_DIR}" ]; then
  echo "- TARGET_BUILD_DIR and BUILT_PRODUCTS_DIR are different. Copying library."
  rm -f "${BUILT_PRODUCTS_DIR}/libsession-util.a"
  rsync -rt "${COMPILE_DIR}/libsession-util.a" "${BUILT_PRODUCTS_DIR}/libsession-util.a"
fi

sync_headers "${COMPILE_DIR}/Headers/"
echo "- Sync complete."

# Output to XCode just so the output is good
echo "LibSession is Ready"
