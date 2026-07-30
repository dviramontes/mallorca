# mallorca — native Odin port of Orca

karl2d_repo := "https://github.com/karl-zylinski/karl2d"

default:
    @just --list

# pinned karl2d revision (update deliberately)
karl2d_rev := "409390f8629132a56446dd744943e4ac2858070e"

# clone karl2d into karl2d/ (vendored dependency, pinned + local patches)
setup:
    test -d karl2d || git clone {{karl2d_repo}} karl2d
    git -C karl2d checkout --detach {{karl2d_rev}}
    git -C karl2d apply ../patches/karl2d-mac-modifier-keys.patch

# no audio playback needed (MIDI in M5 uses CoreMIDI); the CoreAudio
# backend also accrues memory in AudioToolbox internals while idle
defines := "-define:KARL2D_AUDIO_BACKEND=nil"

# type-check all packages without building
check:
    odin check src {{defines}}
    odin check src/core -no-entry-point

# format application and core Odin sources
fmt:
    for f in src/*.odin src/core/*.odin; do [ -f "$f" ] && odinfmt -w "$f"; done

# debug build & run; pass an .orca file to load, and extra flags like --debug
run file="" *flags="":
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}" {{flags}}

# run as the network host (M6 remote play); needs `just server` running.
# `just host` gets a server-assigned room; `just host CODE` joins a specific one.
host room="" *flags="":
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- --net-host --room={{room}} {{flags}}

# debug build
build:
    mkdir -p bin
    odin build src -debug {{defines}} -out:bin/mallorca

# optimized build
release:
    mkdir -p bin
    odin build src -o:speed {{defines}} -out:bin/mallorca

# build an optimized .app bundle with the island icon (macOS Dock/Finder icon)
bundle:
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

# run core simulation tests and host integration tests
test:
    odin test src/core
    odin test src {{defines}}

# fetch server deps and create the SQLite dev database (run once after setup)
server-setup:
    cd server && mix deps.get && mix ecto.create

# run the Phoenix server (M6 remote multiplayer) at http://localhost:4000
server:
    cd server && mix phx.server

# remove build artifacts
clean:
    rm -rf bin
