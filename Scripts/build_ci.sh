#!/bin/bash

IFS=$' \t\n'

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Error: Missing mode. Usage: $0 [test|archive] [unique_xcodebuild_args...]"
    exit 1
fi

COMMIT_MSG="$(git log -1 --format='%s' HEAD)"
echo "--- Log Mode Detection ---"
echo "Latest commit message: '${COMMIT_MSG}'"
if echo "$COMMIT_MSG" | grep -iq '^\[raw\]'; then
    USE_RAW_LOGS=1
    echo "⚠️  [raw] commit prefix detected – xcbeautify and xcresultparser are DISABLED."
    echo "    Raw xcodebuild output will be emitted directly."
    echo ""
else
    USE_RAW_LOGS=0
fi

# Try just in case
xcodebuild -runFirstLaunch

echo "--- SDK Version ---"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo "unknown")"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "unknown")"
echo "iOS SDK version : ${SDK_VERSION}"
echo "iOS SDK path    : ${SDK_PATH}"
echo ""


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
    
    if [[ "$USE_RAW_LOGS" -eq 1 ]]; then
        # Raw mode: pipe directly to tee only, no xcbeautify
        (
            NSUnbufferedIO=YES xcodebuild test \
                "${COMMON_ARGS[@]}" \
                "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG"
        ) || xcodebuild_exit_code=${PIPESTATUS[0]}
    else
        # We wrap the pipeline in parentheses to capture the exit code of xcodebuild
        # which is at PIPESTATUS[0]. We do not use tee to a file here, as the complexity
        # of reading back the UUID is not necessary if we pass it via args.
        (
            NSUnbufferedIO=YES xcodebuild test \
                "${COMMON_ARGS[@]}" \
                "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG" | xcbeautify --is-ci
        ) || xcodebuild_exit_code=${PIPESTATUS[0]}
    fi

    echo ""
    echo "--- xcodebuild finished with exit code: $xcodebuild_exit_code ---"
    
    if [ "$xcodebuild_exit_code" -eq 0 ]; then
        echo "✅ All tests passed and build succeeded!"
        exit 0
    fi

    echo ""
    echo "🔴 Build failed"
    echo "----------------------------------------------------"

    if [[ "$USE_RAW_LOGS" -eq 1 ]]; then
        # Raw mode: skip xcresultparser entirely, show grep summary + tail
        echo "Skipping xcresultparser (raw mode). Scanning raw log for errors..."
        echo ""
        echo "--- Matched Error Lines ---"
        grep -En --color=always \
            '(:[0-9]+:[0-9]+: error:)|(ld: error:)|(error: linker command failed)|(PhaseScriptExecution)|(rsync error:)|(warning: .* error)|(fatal error:)' \
            "$XCODEBUILD_RAW_LOG" || echo "(no lines matched error patterns)"
        echo ""
        echo "--- Last 40 Lines of Raw Log ---"
        tail -n 40 "$XCODEBUILD_RAW_LOG"
        echo "----------------------------------------------------"
        exit "$xcodebuild_exit_code"
    fi

    echo "Checking for test failures in xcresult bundle..."

    xcresultparser --output-format cli --no-test-result --coverage-report-format targets --coverage ./build/artifacts/testResults.xcresult
    parser_output=$(xcresultparser --output-format cli --no-test-result ./build/artifacts/testResults.xcresult)

    # Strip ANSI color codes before parsing
    clean_parser_output=$(echo "$parser_output" | sed 's/\[[0-9;]*m//g')
    build_errors_count=$(echo "$clean_parser_output" | grep "Number of errors" | awk '{print $NF}' | grep -o '[0-9]*' || echo "0")
    failed_tests_count=$(echo "$clean_parser_output" | grep "Number of failed tests" | awk '{print $NF}' | grep -o '[0-9]*' || echo "0")

    if [ "${build_errors_count:-0}" -gt 0 ] || [ "${failed_tests_count:-0}" -gt 0 ]; then
        echo ""
        echo "🔴 Found $build_errors_count build error(s) and $failed_tests_count failed test(s) in the xcresult bundle."
        exit 1
    else
        echo "No test failures found in results. Failure was likely a build error."
        echo ""
        echo "💡 Tip: if no errors are visible above, retry with a [raw] commit prefix"
        echo "   to bypass xcresultparser and see unfiltered xcodebuild output."
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
    
    echo "--- Running Simulator Archive Build (App_Store_Release) ---"
    
    if [[ "$USE_RAW_LOGS" -eq 1 ]]; then
        # Raw mode: no xcbeautify
        NSUnbufferedIO=YES xcodebuild archive \
            "${COMMON_ARGS[@]}" \
            "${UNIQUE_ARGS[@]}" 2>&1
    else
        NSUnbufferedIO=YES xcodebuild archive \
            "${COMMON_ARGS[@]}" \
            "${UNIQUE_ARGS[@]}" 2>&1 | xcbeautify --is-ci
    fi
    
else
    echo "Error: Invalid mode '$MODE' specified. Use 'test' or 'archive'."
    exit 1
fi
