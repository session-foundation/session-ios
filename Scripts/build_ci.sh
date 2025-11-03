#!/bin/bash

IFS=$' \t\n'

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
    
    if [ "$xcodebuild_exit_code" -eq 0 ]; then
        echo "✅ All tests passed and build succeeded!"
        exit 0
    fi

    echo ""
    echo "🔴 Build failed"
    echo "----------------------------------------------------"
    echo "Checking for test failures in xcresult bundle..."

    xcresultparser --output-format cli --no-test-result --coverage ./build/artifacts/testResults.xcresult
    parser_output=$(xcresultparser --output-format cli --no-test-result ./build/artifacts/testResults.xcresult)

    build_errors_count=$(echo "$parser_output" | grep "Number of errors" | awk '{print $NF}' | grep -o '[0-9]*' || echo "0")
    failed_tests_count=$(echo "$parser_output" | grep "Number of failed tests" | awk '{print $NF}' | grep -o '[0-9]*' || echo "0")

    if [ "${build_errors_count:-0}" -gt 0 ] || [ "${failed_tests_count:-0}" -gt 0 ]; then
        echo ""
        echo "🔴 Found $build_errors_count build error(s) and $failed_tests_count failed test(s) in the xcresult bundle."
        exit 1
    else
        echo "No test failures found in results. Failure was likely a build error."
        echo ""

        echo "--- Summary of Potential Build Errors ---"
        grep -E --color=always '(:[0-9]+:[0-9]+: error:)|(ld: error:)|(error: linker command failed)|(PhaseScriptExecution)|(rsync error:)' "$XCODEBUILD_RAW_LOG" || true
        echo ""
        echo "--- End of Raw Log ---"
        tail -n 20 "$XCODEBUILD_RAW_LOG"
        echo "-------------------------"
        exit "$xcodebuild_exit_code"
    fi

    echo "----------------------------------------------------"
    exit "$xcodebuild_exit_code"
    
elif [[ "$MODE" == "archive" ]]; then

    # Clean derived data to prevent race conditions
    rm -rf ./build/derivedData
    
    echo "--- Running Simulator Archive Build (App_Store_Release) ---"
    
    NSUnbufferedIO=YES xcodebuild archive \
        "${COMMON_ARGS[@]}" \
        "${UNIQUE_ARGS[@]}" 2>&1 | xcbeautify --is-ci
    
else
    echo "Error: Invalid mode '$MODE' specified. Use 'test' or 'archive'."
    exit 1
fi
