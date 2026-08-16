cmake_minimum_required(VERSION 3.16)
project(sendspin_player VERSION 0.1.0 LANGUAGES CXX)

# Default to Release; promote -O2 → -O3 before FetchContent so the flag
# propagates into sendspin-cpp's FLAC/Opus decoders and ix-websocket.
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
set(CMAKE_C_FLAGS_RELEASE   "-O3 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG" CACHE STRING "" FORCE)

# Pin sendspin-cpp tightly — the protocol is Experimental upstream and our
# patch (listener-bound hook) must be re-validated on every bump.
# We pin to a commit SHA, not a tag, because git tags are mutable server-
# side: a retag would silently flow into firmware. The friendly tag is kept
# in a comment for traceability. Resolve with `git ls-remote URL TAG` when
# bumping.
#
# FORCE so the repo pin always wins over a stale CMakeCache.txt — without
# it, a pin bump silently keeps building the previous SHA in existing
# build dirs. This also means `-DSENDSPIN_CPP_REF=...` cannot override;
# for scratch experiments against another ref use
# `-DFETCHCONTENT_SOURCE_DIR_SENDSPIN-CPP=<local-checkout>` instead.
set(SENDSPIN_CPP_REF "30514d5102c269a0c7fa6a13932d6bf7f2ae1abc" # v0.7.2
    CACHE STRING "sendspin-cpp commit SHA to pin" FORCE)

# Trim sendspin-cpp to just the player role. Other roles ship dead code on a
# device that only plays audio and cost compile time on slower cross-targets.
set(SENDSPIN_ENABLE_PLAYER     ON  CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_CONTROLLER OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_METADATA   OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_COLOR      OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_ARTWORK    OFF CACHE BOOL "" FORCE)
set(SENDSPIN_ENABLE_VISUALIZER OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
    sendspin-cpp
    GIT_REPOSITORY https://github.com/Sendspin/sendspin-cpp.git
    GIT_TAG        ${SENDSPIN_CPP_REF}
    # GIT_SHALLOW with a SHA is supported by recent CMake but rejected by
    # older git; leave it off for robust SHA-based fetches.
    #
    # Patch idempotency: FetchContent re-runs PATCH_COMMAND on every
    # CMake configure. We can't use `patch -N --forward || true` because
    # that masks real failures (e.g. a partial hunk apply on upstream
    # context drift) — silent breakage would slip past CI and only
    # surface at runtime. Instead, gate the apply on a marker grep: if
    # the patch's marker is already present, the patch has run;
    # otherwise apply with default semantics so any failure (missing
    # context, conflicting edit) is loud and fatal at configure time.
    PATCH_COMMAND  sh -c "grep -q sendspin_host_listener_bound src/host/ws_server.cpp || patch -p1 -i ${CMAKE_CURRENT_LIST_DIR}/patches/0003-listener-bound-hook.patch"
)

# Manual populate + add_subdirectory(EXCLUDE_FROM_ALL) for compatibility with
# CMake 3.16–3.27 where FetchContent_Declare's EXCLUDE_FROM_ALL argument does
# not exist. Keeps sendspin-cpp's example executables (basic_client, tui_client)
# out of the default build.
FetchContent_GetProperties(sendspin-cpp)
if(NOT sendspin-cpp_POPULATED)
    FetchContent_Populate(sendspin-cpp)
    add_subdirectory(${sendspin-cpp_SOURCE_DIR}
                     ${sendspin-cpp_BINARY_DIR}
                     EXCLUDE_FROM_ALL)
endif()

# Defence in depth: verify the patch landed completely. It names TWO
# markers: a comment/declaration sentinel proving the patch ran at all,
# and a functional marker proving the load-bearing hunk landed (a
# partial apply could leave the sentinel while the behavior hunk
# silently no-applied — the weak declaration present but the hook call
# after server start missing).
function(assert_patch_markers patch_label)
    file(READ "${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp" _src)
    foreach(_marker IN LISTS ARGN)
        string(FIND "${_src}" "${_marker}" _pos)
        if(_pos EQUAL -1)
            message(FATAL_ERROR
                "sendspin-cpp patch ${patch_label} did not apply cleanly: "
                "marker '${_marker}' missing from "
                "${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp. "
                "Re-validate patches/${patch_label}.patch against the "
                "current SENDSPIN_CPP_REF (${SENDSPIN_CPP_REF}).")
        endif()
    endforeach()
endfunction()

assert_patch_markers(0003-listener-bound-hook
    "sendspin_host_listener_bound(uint16_t port) __attribute__((weak))"
    "sendspin_host_listener_bound(port)")

add_executable(sendspin_player
    src/main.cpp
    src/alsa_pipe_sink.cpp
    src/alsa_caps.cpp
)

target_link_libraries(sendspin_player
    PRIVATE
        sendspin
        asound
        pthread
)

target_compile_features(sendspin_player PRIVATE cxx_std_20)
target_include_directories(sendspin_player PRIVATE src)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(sendspin_player PRIVATE -Wall -Wextra)
endif()
