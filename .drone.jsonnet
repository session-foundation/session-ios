// Intentionally doing a depth of 2 as libSession-util has it's own submodules (and libLokinet likely will as well)
local clone_submodules = {
  name: 'Clone Submodules',
  commands: ['git fetch --tags', 'git submodule update --init --recursive --depth=2']
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// xcpretty
local install_xcpretty = {
  name: 'Install XCPretty',
  commands: [
    |||
      if [[ $(command -v brew) != "" ]]; then
        brew install xcpretty
      fi
    |||,
    |||
      if [[ $(command -v brew) == "" ]]; then
        gem install xcpretty
      fi
    |||,
  ]
};

// Cocoapods
// 
// Unfortunately Cocoapods has a dumb restriction which requires you to use UTF-8 for the
// 'LANG' env var so we need to work around the with https://github.com/CocoaPods/CocoaPods/issues/6333
local install_cocoapods = {
  name: 'Install CocoaPods',
  commands: ['LANG=en_US.UTF-8 pod install']
};


[
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'Test Upload',
    platform: { os: 'darwin', arch: 'amd64' },
    steps: [
      {
        name: 'Upload artifacts',
        commands: [
          './.drone-static-upload.sh'
        ]
      }
    ]
  },
//  // Unit tests
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'Unit Tests',
//    platform: { os: 'darwin', arch: 'amd64' },
//    steps: [
//      clone_submodules,
//      // install_xcpretty,
//      install_cocoapods,
//      {
//        name: 'Run Unit Tests',
//        commands: [
//          'mkdir build',
//          'xcodebuild test -workspace Session.xcworkspace -scheme Session -destination "platform=iOS Simulator,name=iPhone 14 Pro"' //  | xcpretty --report html'
//        ],
//      },
//    ],
//  },
//  // Simulator build
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'Simulator Build',
//    platform: { os: 'darwin', arch: 'amd64' },
//    steps: [
//      clone_submodules,
//      // install_xcpretty,
//      install_cocoapods,
//      {
//        name: 'Build',
//        commands: [
//          'mkdir build',
//          'xcodebuild -workspace Session.xcworkspace -scheme Session -configuration "App Store Release" -sdk iphonesimulator -derivedDataPath ./build -destination "generic/platform=iOS Simulator"' // | xcpretty'
//        ],
//      },
//      {
//        name: 'Upload artifacts',
//        commands: [
//          './.drone-static-upload.sh'
//        ]
//      }
//    ],
//  },
//  // AppStore build (generate an archive to be signed later)
//  {
//    kind: 'pipeline',
//    type: 'exec',
//    name: 'AppStore Build',
//    platform: { os: 'darwin', arch: 'amd64' },
//    steps: [
//      clone_submodules,
//      // install_xcpretty,
//      install_cocoapods,
//      {
//        name: 'Build',
//        commands: [
//          'mkdir build',
//          'xcodebuild archive -workspace Session.xcworkspace -scheme Session -archivePath ./build/Session.xcarchive -destination "platform=generic/iOS" | xcpretty'
//        ],
//      },
//    ],
//  },
]