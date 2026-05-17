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
    #
    # Patch idempotency: FetchContent re-runs PATCH_COMMAND on every
    # CMake configure. We can't use `patch -N --forward || true` because
    # that masks real failures (e.g. a partial hunk apply on upstream
    # context drift) — silent breakage would slip past CI and only
    # surface when the second player instance failed to bind. Instead,
    # gate the apply on a marker grep: if the env-var hook is already
    # present, the patch has run; otherwise apply with default semantics
    # so any failure (missing context, conflicting edit) is loud and
    # fatal at configure time.
    PATCH_COMMAND  sh -c "grep -q SENDSPIN_WS_PORT src/host/ws_server.cpp || patch -p1 -i ${CMAKE_CURRENT_LIST_DIR}/patches/0001-configurable-ws-port.patch"
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

# Defence in depth: verify the port-config patch landed both halves.
# Marker #1 (env_marker): the SENDSPIN_WS_PORT-reading block exists.
# Marker #2 (bind_marker): the WebSocketServer constructor was actually
# rewritten to use the runtime `port` variable. Without #2, a partial
# apply could leave the env-read block in place while the constructor
# still passes DEFAULT_SERVER_PORT — silently honouring 8928 only.
file(READ "${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp" _ws_server_src)
string(FIND "${_ws_server_src}" "SENDSPIN_WS_PORT" _env_marker)
string(FIND "${_ws_server_src}" "WebSocketServer>(port," _bind_marker)
if(_env_marker EQUAL -1 OR _bind_marker EQUAL -1)
    message(FATAL_ERROR
        "sendspin-cpp port-config patch did not apply cleanly: "
        "env_marker=${_env_marker} bind_marker=${_bind_marker} in "
        "${sendspin-cpp_SOURCE_DIR}/src/host/ws_server.cpp. "
        "Re-validate patches/0001-configurable-ws-port.patch against the "
        "current SENDSPIN_CPP_REF (${SENDSPIN_CPP_REF}).")
endif()
unset(_ws_server_src)
unset(_env_marker)
unset(_bind_marker)

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
