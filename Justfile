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

# debug build & run; pass an .orca file to load it
run file="":
    mkdir -p bin
    odin run src -debug {{defines}} -out:bin/mallorca -- "{{file}}"

# debug build
build:
    mkdir -p bin
    odin build src -debug {{defines}} -out:bin/mallorca

# optimized build
release:
    mkdir -p bin
    odin build src -o:speed {{defines}} -out:bin/mallorca

# run core simulation tests
test:
    odin test src/core

# remove build artifacts
clean:
    rm -rf bin
