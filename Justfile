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

# type-check all packages without building
check:
    odin check src
    odin check src/core -no-entry-point

# debug build & run; pass an .orca file to load it
run file="":
    mkdir -p bin
    odin run src -debug -out:bin/mallorca -- "{{file}}"

# debug build
build:
    mkdir -p bin
    odin build src -debug -out:bin/mallorca

# optimized build
release:
    mkdir -p bin
    odin build src -o:speed -out:bin/mallorca

# run core simulation tests
test:
    odin test src/core

# remove build artifacts
clean:
    rm -rf bin
