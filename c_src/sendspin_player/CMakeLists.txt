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
# patch (configurable WebSocket port) must be re-validated on every bump.
# We pin to a commit SHA, not a tag, because git tags are mutable server-
# side: a retag would silently flow into firmware. The friendly tag is kept
# in a comment for traceability. Resolve with `git ls-remote URL TAG` when
# bumping.
set(SENDSPIN_CPP_REF "573efd520d8a4918a310addc99ce77f6ff9a4e09" # v0.5.0
    CACHE STRING "sendspin-cpp commit SHA to pin")

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
    # -N --forward makes patch idempotent: on first configure the patch
    # applies cleanly; on every subsequent configure (FetchContent re-runs
    # PATCH_COMMAND) it detects the patch is already applied and exits 0.
    # Without this, re-configures fail with "3 out of 3 hunks ignored".
    PATCH_COMMAND  patch -p1 -N --forward -i ${CMAKE_CURRENT_LIST_DIR}/patches/0001-configurable-ws-port.patch || true
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

# Defence in depth: verify our port-config patch landed. If `patch` fuzzy-
# applied at the wrong offset (or silently no-applied due to upstream drift),
# the binary would compile but ignore SENDSPIN_WS_PORT and crash on the
# second player instance. Fail loud at configure time instead.
file(READ "${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp" _ws_server_src)
string(FIND "${_ws_server_src}" "SENDSPIN_WS_PORT" _patch_marker)
if(_patch_marker EQUAL -1)
    message(FATAL_ERROR
        "sendspin-cpp port-config patch did not apply: SENDSPIN_WS_PORT "
        "marker not found in ${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp. "
        "Re-validate patches/0001-configurable-ws-port.patch against the "
        "current SENDSPIN_CPP_REF (${SENDSPIN_CPP_REF}).")
endif()
unset(_ws_server_src)
unset(_patch_marker)

add_executable(sendspin_player
    src/main.cpp
    src/alsa_pipe_sink.cpp
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
