#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Error: Missing mode. Usage: $0 [test|archive] [unique_xcodebuild_args...]"
    exit 1
fi

MODE="$1"
shift

COMMON_ARGS=(
    -project Session.xcodeproj
    -scheme Session
    -derivedDataPath ./build/derivedData
    -parallelizeTargets
    -configuration "App_Store_Release"
)

UNIQUE_ARGS=("$@")
XCODEBUILD_RAW_LOG=$(mktemp)

trap 'rm -f "$XCODEBUILD_RAW_LOG"' EXIT

if [[ "$MODE" == "test" ]]; then
    
    echo "--- Running Build and Unit Tests (App_Store_Release) ---"
    
    xcodebuild_exit_code=0
    
    # We wrap the pipeline in parentheses to capture the exit code of xcodebuild
    # which is at PIPESTATUS[0]. We do not use tee to a file here, as the complexity
    # of reading back the UUID is not necessary if we pass it via args.
    (
        NSUnbufferedIO=YES xcodebuild test \
            "${COMMON_ARGS[@]}" \
            "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG" | xcbeautify --is-ci
    ) || xcodebuild_exit_code=${PIPESTATUS[0]}

    echo ""
    echo "--- xcodebuild finished with exit code: $xcodebuild_exit_code ---"
    
    # Check for a build failure (e.g., compile error, linker issue, or simulator connection error)
    if [ "$xcodebuild_exit_code" -ne 0 ]; then
        echo "🔴 Build failed. See log above for full context."
        echo ""
        echo "--- Summary of Errors ---"
        grep -E --color=always '(:[0-9]+:[0-9]+: error:)|(ld: error:)|(Command PhaseScriptExecution failed)' "$XCODEBUILD_RAW_LOG" || true
        echo "-------------------------"
        exit "$xcodebuild_exit_code"
    fi
    
    echo ""
    echo "✅ Build Succeeded. Verifying test results from xcresult bundle..."
    
    # If the build passed, xcresultparser becomes the final gatekeeper for test results.
    xcresultparser --output-format cli --exit-with-error-on-failure ./build/artifacts/testResults.xcresult
    
elif [[ "$MODE" == "archive" ]]; then
    
    echo "--- Running Simulator Archive Build (App_Store_Release) ---"
    
    NSUnbufferedIO=YES xcodebuild archive \
        "${COMMON_ARGS[@]}" \
        "${UNIQUE_ARGS[@]}" 2>&1 | xcbeautify --is-ci
    
else
    echo "Error: Invalid mode '$MODE' specified. Use 'test' or 'archive'."
    exit 1
fi
