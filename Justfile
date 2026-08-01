# mallorca — native Odin port of Orca

karl2d_repo := "https://github.com/karl-zylinski/karl2d"

default:
    @just --list

# pinned karl2d revision (update deliberately)
karl2d_rev := "409390f8629132a56446dd744943e4ac2858070e"

# the fofoca cargo workspace (p2p rooms, see docs/p2p-protocol.md). Its own repo
# since the extraction; cloned into fofoca/ by `just setup`, same as karl2d.
fofoca_repo := "https://github.com/fofoca-network/fofoca"

# pinned fofoca revision. Bump this after pushing a change to the fofoca repo —
# the dev loop is: edit in fofoca/, `just check` here, push there, bump here.
fofoca_rev := "53df47bf4f4a55ddff476faec7e496339006cfce"

fofoca_manifest := "fofoca/Cargo.toml"

# clone the two vendored dependencies at their pinned revisions
setup:
    test -d karl2d || git clone {{karl2d_repo}} karl2d
    git -C karl2d checkout --detach {{karl2d_rev}}
    # `checkout --detach` keeps local modifications, so the patch survives a
    # re-run and applying it again fails. If it reverses cleanly it is already
    # in place — skip. Without this, `setup` is a one-shot recipe.
    git -C karl2d apply --reverse --check ../patches/karl2d-mac-modifier-keys.patch 2>/dev/null \
      || git -C karl2d apply ../patches/karl2d-mac-modifier-keys.patch
    test -d fofoca || git clone {{fofoca_repo}} fofoca
    git -C fofoca fetch --quiet origin
    git -C fofoca checkout --detach --quiet {{fofoca_rev}}

# no audio playback needed (MIDI in M5 uses CoreMIDI); the CoreAudio
# backend also accrues memory in AudioToolbox internals while idle
defines := "-define:KARL2D_AUDIO_BACKEND=nil"

# build the fofoca FFI staticlib and copy it to the path src links against.
# Every build recipe depends on this one but none depend on `setup`, so clone
# on demand rather than failing with a bare "no such manifest".
fofoca:
    @test -d fofoca || just setup
    cargo build --release -p fofoca-ffi --manifest-path {{fofoca_manifest}}
    mkdir -p fofoca/lib
    cp fofoca/target/release/libfofoca_ffi.a fofoca/lib/

# type-check all packages without building
check: fofoca
    odin check src {{defines}}
    odin check src/core -no-entry-point
    odin check src/p2p -no-entry-point

# format application and core Odin sources
fmt:
    for f in src/*.odin src/core/*.odin src/p2p/*.odin; do [ -f "$f" ] && odinfmt -w "$f"; done

# debug build & run; pass an .orca file to load, and extra flags (see docs/p2p-protocol.md)
run file="" *flags="": fofoca
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" {{flags}}

# create a p2p room and open `file` (optional), optionally naming the room
create-room file="" room_name="": fofoca
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" --create-room {{ if room_name != "" { "--room-name=" + room_name } else { "" } }}

# join a p2p room by its bare base58 hash (printed by create-room)
join-room hash file="": fofoca
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" --join-room={{hash}}

# debug build
build: fofoca
    mkdir -p bin
    odin build src -debug {{defines}} -out:bin/mallorca

# optimized build
release: fofoca
    mkdir -p bin
    odin build src -o:speed {{defines}} -out:bin/mallorca

# build an optimized .app bundle with the island icon (macOS Dock/Finder icon)
bundle: fofoca
    mkdir -p bin
    odin build src -o:speed {{defines}} -out:bin/mallorca
    rm -rf bin/Mallorca.app
    mkdir -p bin/Mallorca.app/Contents/MacOS bin/Mallorca.app/Contents/Resources
    cp bin/mallorca bin/Mallorca.app/Contents/MacOS/mallorca
    cp assets/mallorca.icns bin/Mallorca.app/Contents/Resources/mallorca.icns
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' \
      '<dict>' \
      '    <key>CFBundleName</key><string>Mallorca</string>' \
      '    <key>CFBundleDisplayName</key><string>Mallorca</string>' \
      '    <key>CFBundleExecutable</key><string>mallorca</string>' \
      '    <key>CFBundleIconFile</key><string>mallorca</string>' \
      '    <key>CFBundleIdentifier</key><string>com.dviramontes.mallorca</string>' \
      '    <key>CFBundleShortVersionString</key><string>0.5.0</string>' \
      '    <key>CFBundleVersion</key><string>0.5.0</string>' \
      '    <key>CFBundlePackageType</key><string>APPL</string>' \
      '    <key>LSMinimumSystemVersion</key><string>11.0</string>' \
      '    <key>NSHighResolutionCapable</key><true/>' \
      '</dict>' \
      '</plist>' \
      > bin/Mallorca.app/Contents/Info.plist
    plutil -lint bin/Mallorca.app/Contents/Info.plist
    @echo "built bin/Mallorca.app"

# optimized build with timing instrumentation compiled in (see src/profile.odin);
# accepts --profile-run=<seconds> and --profile-no-play
profile: fofoca
    mkdir -p bin
    odin build src -o:speed {{defines}} -define:MALLORCA_PROFILE=true -out:bin/mallorca-prof

# measure what the mesh FFI costs: size, CPU, RAM (see docs/ffi-cost.md).
# `just measure size` skips the runtime matrix, which needs an idle machine.
measure phase="all": fofoca
    ./scripts/measure-ffi-cost.sh {{phase}}

# run core simulation tests and app package tests
test: fofoca
    odin test src/core
    odin test src/p2p
    odin test src {{defines}}

# remove build artifacts
clean:
    rm -rf bin

# remove the fofoca workspace's build output (not part of `clean`)
clean-fofoca:
    cargo clean --manifest-path {{fofoca_manifest}}
