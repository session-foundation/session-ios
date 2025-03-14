// This build configuration requires the following to be installed:
// Git, Xcode, XCode Command-line Tools, xcbeautify, xcresultparser

// Log a bunch of version information to make it easier for debugging
local version_info = {
  name: 'Version Information',
  environment: { LANG: 'en_US.UTF-8' },
  commands: [
    'git --version',
    'xcodebuild -version',
    'xcbeautify --version',
    'xcresultparser --version'
  ],
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

local boot_simulator(device_type="") = {
  name: 'Boot Test Simulator',
  commands: [
    'devname="Test-iPhone-${DRONE_COMMIT:0:9}-${DRONE_BUILD_EVENT}"',
    (if device_type != "" then
       'xcrun simctl create "$devname" ' + device_type
     else
      'device_type=$(xcrun simctl list devicetypes -j | ' +
        'jq -r \'.devicetypes | map(select(.productFamily=="iPhone")) | sort_by(.minRuntimeVersion) | .[-1].identifier\' | tail -n1); ' +
        'xcrun simctl create "$devname" "$device_type"'
    ),
    'sim_uuid=$(xcrun simctl list devices -je | jq -re \'[.devices[][] | select(.name == "\'$devname\'").udid][0]\')',
    'xcrun simctl boot $sim_uuid',

    'mkdir -p build/artifacts',
    'echo $sim_uuid > ./build/artifacts/sim_uuid',
    'echo $devname > ./build/artifacts/device_name',

    'xcrun simctl list -je devices $sim_uuid | jq -r \'.devices[][0] | "\\u001b[32;1mSimulator " + .state + ": \\u001b[34m" + .name + " (\\u001b[35m" + .deviceTypeIdentifier + ", \\u001b[36m" + .udid + "\\u001b[34m)\\u001b[0m"\'',
  ],
};
local sim_keepalive = {
  name: '(Simulator keep-alive)',
  commands: [
    '/Users/$USER/sim-keepalive/keepalive.sh $(<./build/artifacts/sim_uuid)',
  ],
  depends_on: ['Boot Test Simulator'],
};
local sim_delete_cmd = 'if [ -f build/artifacts/sim_uuid ]; then rm -f /Users/$USER/sim-keepalive/$(<./build/artifacts/sim_uuid); fi';

[
  // Unit tests (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['push'] } },
    steps: [
      version_info,

      boot_simulator(),
      sim_keepalive,
      {
        name: 'Build and Run Tests',
        commands: [
          'NSUnbufferedIO=YES set -o pipefail && xcodebuild test -project Session.xcodeproj -scheme Session -derivedDataPath ./build/derivedData -resultBundlePath ./build/artifacts/testResults.xcresult -parallelizeTargets -destination "platform=iOS Simulator,id=$(<./build/artifacts/sim_uuid)" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -collect-test-diagnostics never 2>&1 | xcbeautify --is-ci',
        ],
        depends_on: [
          'Boot Test Simulator'
        ],
      },
      {
        name: 'Unit Test Summary',
        commands: [
          sim_delete_cmd,
          'xcresultparser --output-format cli --failed-tests-only ./build/artifacts/testResults.xcresult'
        ],
        depends_on: ['Build and Run Tests']
      },
      {
        name: 'Convert xcresult to xml',
        commands: [
          'xcresultparser --output-format cobertura ./build/artifacts/testResults.xcresult > ./build/artifacts/coverage.xml',
        ],
        depends_on: ['Build and Run Tests'],
      },
    ],
  },
  // Validate build artifact was created by the direct branch push (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Check Build Artifact Existence',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['push'] } },
    steps: [
      {
        name: 'Poll for build artifact existence',
        commands: [
          './Scripts/drone-upload-exists.sh',
        ],
      },
    ],
  },
  // Simulator build (non-PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Simulator Build',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: ['pull_request'] } },
    steps: [
      version_info,
      {
        name: 'Build',
        commands: [
          'mkdir build',
          'NSUnbufferedIO=YES set -o pipefail && xcodebuild archive -project Session.xcodeproj -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App_Store_Release" -sdk iphonesimulator -archivePath ./build/Session_sim.xcarchive -destination "generic/platform=iOS Simulator" | xcbeautify --is-ci',
        ],
      },
      {
        name: 'Upload artifacts',
        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
        commands: [
          './Scripts/drone-static-upload.sh',
        ],
        depends_on: [
          'Build',
        ],
      },
    ],
  },
]
