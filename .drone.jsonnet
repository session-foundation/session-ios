local submodule_commands = ['git fetch --tags', 'git submodule update --init --recursive --depth=1'];

local submodules = {
  name: 'submodules',
  image: 'drone/git',
  commands: submodule_commands,
};

// cmake options for static deps mirror
local ci_dep_mirror(want_mirror) = (if want_mirror then ' -DLOCAL_MIRROR=https://oxen.rocks/deps ' else '');

// Macos build
local mac_builder(name,
                  build_type='Release',
                  werror=true,
                  cmake_extra='',
                  local_mirror=true,
                  extra_cmds=[],
                  jobs=6,
                  codesign='-DCODESIGN=OFF',
                  allow_fail=false) = {
  kind: 'pipeline',
  type: 'exec',
  name: name,
  platform: { os: 'darwin', arch: 'amd64' },
  steps: [
    { name: 'submodules', commands: submodule_commands },
    {
      name: 'build',
      environment: { SSH_KEY: { from_secret: 'SSH_KEY' } },
      commands: [
        'echo "Building on ${DRONE_STAGE_MACHINE}"',
        // If you don't do this then the C compiler doesn't have an include path containing
        // basic system headers.  WTF apple:
        'export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"',
        'ulimit -n 1024',  // because macos sets ulimit to 256 for some reason yeah idk
        './contrib/mac-configure.sh ' +
        ci_dep_mirror(local_mirror) +
        (if build_type == 'Debug' then ' -DWARN_DEPRECATED=OFF ' else '') +
        codesign,
        'cd build-mac',
        // We can't use the 'package' target here because making a .dmg requires an active logged in
        // macos gui to invoke Finder to invoke the partitioning tool to create a partitioned (!)
        // disk image.  Most likely the GUI is required because if you lose sight of how pretty the
        // surface of macOS is you might see how ugly the insides are.
        'ninja -j' + jobs + ' assemble_gui',
        'cd ..',
      ] + extra_cmds,
    },
  ],
};


[
  // TODO: Unit tests
  // TODO: Build for UI testing
  // TODO: Production build
  {
    kind: 'pipeline',
    type: 'exec',
    name: 'MacOS',
    platform: { os: 'darwin', arch: 'amd64' },
    steps: [
      // TODO: Need a depth of 2? (libSession-util has it's own submodules)
      { name: 'submodules', commands: submodule_commands },
      {
        name: 'build',
        commands: [
          'echo "This is a test message"',
        ],
      },
    ],
  },
]