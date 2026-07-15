#!/usr/bin/env bash
# One-command build driver: resolve dependencies, configure, build, test.
#
# usage: scripts/build.sh [debug|release|asan|tsan] [--clean] [--profile <name-or-path>]
#
#   debug (default), release   normal builds
#   asan, tsan                 sanitizer builds (reuse the Debug dependency install)
#   --clean                    delete build/ first
#   --profile <p>              Conan profile: a name under /opt/conan/profiles
#                              (inside the dev container) or a path. Outside the
#                              container, defaults to Conan's detected profile.
#
# The script prints every command it runs — it is a convenience, not a layer
# of magic. CI runs the same underlying commands explicitly; if this script
# disappeared, only convenience would be lost. On native Windows, use the raw
# commands from README.md / .github/workflows/ci.yml.
set -euo pipefail

run() {
    echo "+ $*" >&2
    "$@"
}

PRESET=debug
CLEAN=0
PROFILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        debug | release | asan | tsan) PRESET=$1 ;;
        --clean) CLEAN=1 ;;
        --profile)
            PROFILE=$2
            shift
            ;;
        *)
            echo "unknown argument: $1 (see header of $0)" >&2
            exit 1
            ;;
    esac
    shift
done

# Sanitizer presets are compiled against the Debug dependency install
# (their toolchainFile in CMakePresets.json points at build/Debug/generators).
case $PRESET in
    release) BUILD_TYPE=Release ;;
    *) BUILD_TYPE=Debug ;;
esac

cd "$(dirname "$0")/.."

# Resolve the profile: team profiles live in the dev image; on a bare host
# fall back to Conan's auto-detected profile pinned to C++23.
PROFILE_ARGS=()
if [[ -n $PROFILE ]]; then
    if [[ -f /opt/conan/profiles/$PROFILE ]]; then
        PROFILE=/opt/conan/profiles/$PROFILE
    fi
    PROFILE_ARGS=(-pr:a "$PROFILE")
elif [[ -d /opt/conan/profiles ]]; then
    PROFILE=/opt/conan/profiles/linux-gcc14
    PROFILE_ARGS=(-pr:a "$PROFILE")
else
    PROFILE=default
    if [[ ! -f "$(conan config home)/profiles/default" ]]; then
        run conan profile detect
    fi
    PROFILE_ARGS=(-s compiler.cppstd=23)
fi

# Switching compiler profiles requires a clean tree: CMake caches the compiler
# and silently ignores a changed toolchain in an existing build directory.
if [[ $CLEAN -eq 1 ]]; then
    run rm -rf build
elif [[ -f build/.last-profile && "$(cat build/.last-profile)" != "$PROFILE" ]]; then
    echo "profile changed ($(cat build/.last-profile) -> $PROFILE): cleaning build/" >&2
    run rm -rf build
fi

run conan install . --build=missing "${PROFILE_ARGS[@]}" -s build_type=$BUILD_TYPE
mkdir -p build
echo "$PROFILE" > build/.last-profile

run cmake --preset "$PRESET"
run cmake --build --preset "$PRESET"
run ctest --preset "$PRESET"
