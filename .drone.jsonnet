// This build configuration requires the following to be installed:
// Git, Xcode, XCode Command-line Tools, Cocoapods, Xcbeautify, Xcresultparser, pip

// Log a bunch of version information to make it easier for debugging
local version_info = {
  name: 'Version Information',
  commands: [
    'git --version',
    'LANG=en_US.UTF-8 pod --version',
    'xcodebuild -version',
    'xcbeautify --version'
  ]
};

// Intentionally doing a depth of 2 as libSession-util has it's own submodules (and libLokinet likely will as well)
local clone_submodules = {
  name: 'Clone Submodules',
  commands: [ 'git submodule update --init --recursive --depth=2 --jobs=4' ]
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// Cocoapods
// 
// Unfortunately Cocoapods has a dumb restriction which requires you to use UTF-8 for the
// 'LANG' env var so we need to work around the with https://github.com/CocoaPods/CocoaPods/issues/6333
local install_cocoapods = {
  name: 'Install CocoaPods',
  commands: ['
    LANG=en_US.UTF-8 pod install || rm -rf ./Pods && LANG=en_US.UTF-8 pod install
  '],
  depends_on: [
    'Load CocoaPods Cache'
  ]
};

// Load from the cached CocoaPods directory (to speed up the build)
local load_cocoapods_cache = {
  name: 'Load CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d /Users/drone/.cocoapods_cache ]]; then
        cp -r /Users/drone/.cocoapods_cache ./Pods
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: [
    'Clone Submodules'
  ]
};

// Override the cached CocoaPods directory (to speed up the next build)
local update_cocoapods_cache(depends_on) = {
  name: 'Update CocoaPods Cache',
  commands: [
    |||
      LOOP_BREAK=0
      while test -e /Users/drone/.cocoapods_cache.lock; do
          sleep 1
          LOOP_BREAK=$((LOOP_BREAK + 1))

          if [[ $LOOP_BREAK -ge 600 ]]; then
            rm -f /Users/drone/.cocoapods_cache.lock
          fi
      done
    |||,
    'touch /Users/drone/.cocoapods_cache.lock',
    |||
      if [[ -d ./Pods ]]; then
        rsync -a --delete ./Pods/ /Users/drone/.cocoapods_cache
      fi
    |||,
    'rm -f /Users/drone/.cocoapods_cache.lock'
  ],
  depends_on: depends_on,
};

// Unit tests
//
// The following 4 steps need to be run in order to run the unit tests
local pre_boot_test_sim = {
  name: 'Pre-Boot Test Simulator',
  commands: [
    'mkdir -p build/artifacts',
    'echo "Test-iPhone14-${DRONE_COMMIT:0:9}-${DRONE_BUILD_EVENT}" > ./build/artifacts/device_name',
    'xcrun simctl create "$(<./build/artifacts/device_name)" com.apple.CoreSimulator.SimDeviceType.iPhone-14',
    'echo $(xcrun simctl list devices | grep -m 1 $(<./build/artifacts/device_name) | grep -E -o -i "([0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12})") > ./build/artifacts/sim_uuid',
    'xcrun simctl boot $(<./build/artifacts/sim_uuid)',
    'echo "[32mPre-booting simulator complete: $(xcrun simctl list | sed "s/^[[:space:]]*//" | grep -o ".*$(<./build/artifacts/sim_uuid).*")[0m"',
    'echo "[32mNumber of Simulators: $(ls -1 /Users/drone/Library/Developer/CoreSimulator/Devices | wc -l)[0m"',
  ]
};

local clean_up_test_simulator = {
  name: 'Clean Up Test Simulator',
  commands: [
    |||
      function handle_exit() {
        xcrun simctl delete unavailable

        if [ -e build/artifacts/sim_uuid ]; then
            xcrun simctl delete $(<./build/artifacts/sim_uuid)
            echo -e "\n\n\n\n\e[32mSimulator $(<./build/artifacts/sim_uuid) deleted.\e[0m\n\n\n"
        else
          echo -e "\n\n\n\n\e[31mSimulator not deleted.\e[0m\n\n\n"
        fi
        exit 0
      }

      trap handle_exit EXIT

      while true; do
        sleep 10
      done
    |||
//    './Scripts/clean-up-test-simulator.sh $(<./build/artifacts/sim_uuid)'
  ],
  depends_on: [
    'Pre-Boot Test Simulator',
  ]
};

local build_and_run_tests = {
  name: 'Build and Run Tests',
  commands: [
    'NSUnbufferedIO=YES set -o pipefail && xcodebuild test -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -resultBundlePath ./build/artifacts/testResults.xcresult -parallelizeTargets -destination "platform=iOS Simulator,id=$(<./build/artifacts/sim_uuid)" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 10 -collect-test-diagnostics never 2>&1 | xcbeautify --is-ci',
  ],
  depends_on: [
    'Pre-Boot Test Simulator',
    'Install CocoaPods'
  ],
};

local unit_test_summary = {
  name: 'Unit Test Summary',
  commands: [
    |||
      if [[ -d ./build/artifacts/testResults.xcresult ]]; then
        xcresultparser --output-format cli --failed-tests-only ./build/artifacts/testResults.xcresult
      else
        echo -e "\n\n\n\e[31;1mUnit test results not found\e[0m"
      fi
    |||,
  ],
  depends_on: ['Build and Run Tests'],
  when: {
    status: ['failure', 'success']
  }
};

[
  // Unit tests (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: [ 'push' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      pre_boot_test_sim,
      clean_up_test_simulator,
      build_and_run_tests,
      unit_test_summary,
      update_cocoapods_cache(['Build and Run Tests'])
    ],
  },
  // Validate build artifact was created by the direct branch push (PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Check Build Artifact Existence',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: [ 'push' ] } },
    steps: [
      {
        name: 'Poll for build artifact existence',
        commands: [
          './Scripts/drone-upload-exists.sh'
        ]
      }
    ]
  },
  // Simulator build (non-PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Simulator Build',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: [ 'pull_request' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      {
        name: 'Build',
        commands: [
          'mkdir build',
          'xcodebuild archive -workspace Session.xcworkspace -scheme Session -derivedDataPath ./build/derivedData -parallelizeTargets -configuration "App Store Release" -sdk iphonesimulator -archivePath ./build/Session_sim.xcarchive -destination "generic/platform=iOS Simulator" | xcbeautify --is-ci'
        ],
        depends_on: [
          'Install CocoaPods'
        ],
      },
      update_cocoapods_cache(['Build']),
      {
        name: 'Upload artifacts',
        environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
        commands: [
          './Scripts/drone-static-upload.sh'
        ],
        depends_on: [
          'Build'
        ]
      },
    ],
  },
  // Unit tests and code coverage (non-PRs only)
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Unit Tests and Code Coverage',
    platform: { os: 'darwin', arch: 'arm64' },
    trigger: { event: { exclude: [ 'pull_request' ] } },
    steps: [
      version_info,
      clone_submodules,
      load_cocoapods_cache,
      install_cocoapods,
      pre_boot_test_sim,
      clean_up_test_simulator,
      build_and_run_tests,
      unit_test_summary,
      update_cocoapods_cache(['Build and Run Tests']),
      {
        name: 'Install Codecov CLI',
        commands: [
          'pip3 install codecov-cli 2>&1 | grep "The script codecovcli is installed in" | sed -n -e "s/^.*The script codecovcli is installed in //p" | sed -n -e "s/ which is not on PATH.$//p" > ./build/artifacts/codecov_install_path',
          |||
            if [[ ! -s ./build/artifacts/codecov_install_path ]]; then
              which codecovcli > ./build/artifacts/codecov_install_path
            fi
          |||,
          '$(<./build/artifacts/codecov_install_path)/codecovcli --version'
        ],
      },
      {
        name: 'Convert xcresult to xml',
        commands: [
          'xcresultparser --output-format cobertura ./build/artifacts/testResults.xcresult > ./build/artifacts/coverage.xml',
        ],
        depends_on: ['Build and Run Tests']
      },
      {
        name: 'Upload coverage to Codecov',
        environment: { CODECOV_TOKEN: { from_secret: 'CODECOV_TOKEN' } },
        commands: [
          '$(<./build/artifacts/codecov_install_path)/codecovcli upload-process --fail-on-error -f ./build/artifacts/coverage.xml',
        ],
        depends_on: [
          'Convert xcresult to xml',
          'Install Codecov CLI'
        ]
      },
    ],
  },
]
