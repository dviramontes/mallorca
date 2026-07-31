# mallorca — native Odin port of Orca

karl2d_repo := "https://github.com/karl-zylinski/karl2d"

default:
    @just --list

# pinned karl2d revision (update deliberately)
karl2d_rev := "409390f8629132a56446dd744943e4ac2858070e"

# vendored agent-habilis-mesh cargo workspace (p2p rooms, see docs/p2p-protocol.md)
mesh_manifest := "agent-habilis-mesh/Cargo.toml"

# clone karl2d into karl2d/ (vendored dependency, pinned + local patches)
setup:
    test -d karl2d || git clone {{karl2d_repo}} karl2d
    git -C karl2d checkout --detach {{karl2d_rev}}
    git -C karl2d apply ../patches/karl2d-mac-modifier-keys.patch

# no audio playback needed (MIDI in M5 uses CoreMIDI); the CoreAudio
# backend also accrues memory in AudioToolbox internals while idle
defines := "-define:KARL2D_AUDIO_BACKEND=nil"

# build the mesh FFI staticlib and copy it to the path src links against
mesh:
    cargo build --release -p agent-habilis-mesh-ffi --manifest-path {{mesh_manifest}}
    mkdir -p agent-habilis-mesh/lib
    cp agent-habilis-mesh/target/release/libagent_habilis_mesh_ffi.a agent-habilis-mesh/lib/

# type-check all packages without building
check: mesh
    odin check src {{defines}}
    odin check src/core -no-entry-point

# format application and core Odin sources
fmt:
    for f in src/*.odin src/core/*.odin; do [ -f "$f" ] && odinfmt -w "$f"; done

# debug build & run; pass an .orca file to load, and extra flags (see docs/p2p-protocol.md)
run file="" *flags="": mesh
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" {{flags}}

# create a p2p room and open `file` (optional), optionally naming the room
create-room file="" room_name="": mesh
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" --create-room {{ if room_name != "" { "--room-name=" + room_name } else { "" } }}

# join a p2p room by its bare base58 hash (printed by create-room)
join-room hash file="": mesh
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" --join-room={{hash}}

# debug build
build: mesh
    mkdir -p bin
    odin build src -debug {{defines}} -out:bin/mallorca

# optimized build
release: mesh
    mkdir -p bin
    odin build src -o:speed {{defines}} -out:bin/mallorca

# build an optimized .app bundle with the island icon (macOS Dock/Finder icon)
bundle: mesh
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

# run core simulation tests and app package tests
test: mesh
    odin test src/core
    odin test src {{defines}}

# remove build artifacts
clean:
    rm -rf bin

# remove the vendored mesh workspace's build output (not part of `clean`)
clean-mesh:
    cargo clean --manifest-path {{mesh_manifest}}
