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

    TEST_SUITES=(
        "SessionTests"
        "SessionUtilitiesKitTests"
        "SessionNetworkingKitTests"
        "SessionMessagingKitTests"
    )

    # Extract the sim UUID from the destination arg so we can bounce it
    SIM_UUID=""
    for arg in "${UNIQUE_ARGS[@]}"; do
        if [[ "$arg" =~ id=([A-F0-9-]{36}) ]]; then
            SIM_UUID="${BASH_REMATCH[1]}"
            break
        fi
    done
    
    overall_exit_code=0
    mkdir -p ./build/artifacts/suites

    # Build once
    echo "--- Building for Testing ---"
    if [[ "$USE_RAW_LOGS" -eq 1 ]]; then
        NSUnbufferedIO=YES xcodebuild build-for-testing \
            "${COMMON_ARGS[@]}" \
            "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG"
    else
        NSUnbufferedIO=YES xcodebuild build-for-testing \
            "${COMMON_ARGS[@]}" \
            "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG" | xcbeautify --is-ci
    fi
    
    for suite in "${TEST_SUITES[@]}"; do
        echo ""
        echo "========================================"
        echo "▶ Running suite: $suite"
        echo "========================================"

        # Bounce simulator between suites
        if [[ -n "$SIM_UUID" ]]; then
            echo "Bouncing simulator $SIM_UUID..."
            xcrun simctl shutdown "$SIM_UUID" 2>/dev/null || true
            
            # Wait until fully shut down before attempting to boot
            echo "Waiting for simulator to shut down..."
            for i in $(seq 1 30); do
                state=$(xcrun simctl list devices -je | jq -r --arg uuid "$SIM_UUID" '.devices[][] | select(.udid == $uuid) | .state' 2>/dev/null || echo "")
                if [[ "$state" == "Shutdown" ]]; then
                    echo "Simulator shut down."
                    break
                fi
                sleep 1
            done

            # Block until simulator reports booted
            xcrun simctl boot "$SIM_UUID"
            xcrun simctl bootstatus "$SIM_UUID" -b

            # Allow simulator to fully settle before launching a hosted test bundle
            sleep 5
            echo "Simulator ready."
        fi

        suite_exit_code=0

        for attempt in 1 2 3; do
            [[ $attempt -gt 1 ]] && echo "⚠️ Retrying suite (attempt $attempt)..."

            suite_result="./build/artifacts/suites/${suite}.xcresult"
            suite_exit_code=0

            # Remove any existing result bundle before attempting
            rm -rf "$suite_result"

            if [[ "$USE_RAW_LOGS" -eq 1 ]]; then
                (
                    NSUnbufferedIO=YES xcodebuild test-without-building \
                        "${COMMON_ARGS[@]}" \
                        -only-testing "$suite" \
                        -resultBundlePath "$suite_result" \
                        "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG"
                ) || suite_exit_code=${PIPESTATUS[0]}
            else
                (
                    NSUnbufferedIO=YES xcodebuild test-without-building \
                        "${COMMON_ARGS[@]}" \
                        -only-testing "$suite" \
                        -resultBundlePath "$suite_result" \
                        "${UNIQUE_ARGS[@]}" 2>&1 | tee "$XCODEBUILD_RAW_LOG" | xcbeautify --is-ci
                ) || suite_exit_code=${PIPESTATUS[0]}
            fi

            # If we got a successful result then no need to loop
            if [[ $suite_exit_code -eq 0 ]]; then
                break
            fi

            # Only retry on a bootstrapping failure (exit 65 with no test output)
            # If there are actual test failures the xcresult will contain them
            suite_result_path="./build/artifacts/suites/${suite}.xcresult"
            test_count=$(xcrun xcresulttool get --path "$suite_result_path" --format json 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metrics',{}).get('testsCount',{}).get('_value','0'))" 2>/dev/null || echo "0")

            if [[ "$test_count" != "0" ]]; then
                echo "Tests ran but failed — not retrying."
                break
            fi

            # Give the simulator 5 seconds to settle before trying again
            sleep 5
        done

        echo "--- $suite finished with exit code: $suite_exit_code ---"

        if [ "$suite_exit_code" -ne 0 ]; then
            overall_exit_code=$suite_exit_code
            echo "🔴 $suite FAILED"
        else
            echo "✅ $suite passed"
        fi
    done

    # Merge all xcresult bundles into the expected output path
    echo ""
    echo "--- Merging xcresult bundles ---"
    xcrun xcresulttool merge ./build/artifacts/suites/*.xcresult \
        --output-path ./build/artifacts/testResults.xcresult

    echo ""
    echo "--- xcodebuild finished with exit code: $overall_exit_code ---"

    if [ "$overall_exit_code" -eq 0 ]; then
        echo "✅ All test suites passed!"
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
        exit "$overall_exit_code"
    fi

    echo "----------------------------------------------------"
    exit "$overall_exit_code"
    
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
