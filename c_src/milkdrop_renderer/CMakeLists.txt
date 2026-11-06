cmake_minimum_required(VERSION 3.21)
project(milkdrop_renderer VERSION 0.1.0 LANGUAGES C CXX)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
set(CMAKE_C_FLAGS_RELEASE   "-O2 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG" CACHE STRING "" FORCE)

set(MILKDROP_CORE_SOURCES
    src/cost_guard.cpp
    src/frame_pacer.cpp
    src/json.cpp
    src/manifest.cpp
    src/options.cpp
    src/pcm_feed.cpp
    src/preset_manager.cpp
    src/protocol.cpp
    src/stderr_capture.cpp
    src/test_tone.cpp
    src/thermal.cpp
)

find_package(Threads REQUIRED)

add_library(milkdrop_core STATIC ${MILKDROP_CORE_SOURCES})
target_compile_features(milkdrop_core PUBLIC cxx_std_20)
target_include_directories(milkdrop_core PUBLIC src)
target_link_libraries(milkdrop_core PUBLIC Threads::Threads)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(milkdrop_core PRIVATE -Wall -Wextra)
endif()

# Host unit tests for the core. Not part of the default build;
# test/milkdrop_renderer_unit_test.exs builds and runs it. The PCM tests
# write the ring with sendspin_player's own writer (the real producer).
add_executable(milkdrop_renderer_unit_tests EXCLUDE_FROM_ALL test/unit_tests.cpp test/ring_writer.cpp)
target_link_libraries(milkdrop_renderer_unit_tests PRIVATE milkdrop_core)
target_include_directories(milkdrop_renderer_unit_tests PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/../sendspin_player/src)
