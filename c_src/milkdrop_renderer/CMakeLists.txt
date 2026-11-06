cmake_minimum_required(VERSION 3.21)
project(milkdrop_renderer VERSION 0.1.0 LANGUAGES C CXX)

# MILKDROP_CORE_ONLY builds just the GL-free core and its unit tests: the
# host build (no KMS master, and no projectM fetch on CI). Device targets
# build the renderer against projectM, Mesa GLES/EGL, GBM and libdrm.
option(MILKDROP_CORE_ONLY "Build only the GL-free core and unit tests" OFF)
# rpi3 (Mesa vc4) has GLES 2.0 only; rpi4/rpi5 (v3d) take the upstream
# GLES 3 path of the same fork.
option(MILKDROP_GLES2 "Build projectM and the renderer for OpenGL ES 2.0" OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
set(CMAKE_C_FLAGS_RELEASE   "-O2 -DNDEBUG" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-O2 -DNDEBUG" CACHE STRING "" FORCE)

set(MILKDROP_CORE_SOURCES
    src/cost_guard.cpp
    src/exit_guard.cpp
    src/frame_pacer.cpp
    src/json.cpp
    src/manifest.cpp
    src/options.cpp
    src/pcm_feed.cpp
    src/preset_manager.cpp
    src/preset_selection.cpp
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

if(MILKDROP_CORE_ONLY)
    return()
endif()

# --- projectM -----------------------------------------------------------
#
# Our fork (bbangert/projectm) adds the GLES 2.0 backend, the GLSL ES 1.00
# translator, the pre-translated shader cache, preset preloading and
# per-preset load results; the renderer needs all of them. Pinned by commit
# SHA (tags are mutable server-side); FORCE so a pin bump always wins over
# a stale CMakeCache.txt. For scratch
# builds against a local checkout set MILKDROP_PROJECTM_SOURCE_DIR (the mix
# compiler forwards it as FETCHCONTENT_SOURCE_DIR_PROJECTM).
set(PROJECTM_REF "bb940dbc5211a3b61d7675542c6a82e2c760cd85" # es2/1d-cache
    CACHE STRING "projectM fork commit SHA to pin" FORCE)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_PLAYLIST OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_PROJECTM_EVAL OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_GLM OFF CACHE BOOL "" FORCE)
set(ENABLE_SDL_UI OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES ON CACHE BOOL "" FORCE)
set(ENABLE_GLES2 ${MILKDROP_GLES2} CACHE BOOL "" FORCE)
set(ENABLE_GLES_SMOKE_TEST OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_TRANSLATOR_HARNESS OFF CACHE BOOL "" FORCE)

include(FetchContent)
FetchContent_Declare(
    projectm
    GIT_REPOSITORY https://github.com/bbangert/projectm.git
    GIT_TAG        ${PROJECTM_REF}
    GIT_SUBMODULES vendor/projectm-eval
)
FetchContent_MakeAvailable(projectm)

if(FETCHCONTENT_SOURCE_DIR_PROJECTM)
    execute_process(
        COMMAND git -C "${FETCHCONTENT_SOURCE_DIR_PROJECTM}" rev-parse HEAD
        OUTPUT_VARIABLE _projectm_head OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(NOT _projectm_head STREQUAL PROJECTM_REF)
        message(WARNING "projectM override ${FETCHCONTENT_SOURCE_DIR_PROJECTM} is at "
                        "'${_projectm_head}', not the pinned ${PROJECTM_REF}")
    endif()
endif()

# --- system libraries (the Nerves toolchain file roots these in the sysroot)
find_path(EGL_INCLUDE_DIR EGL/egl.h)
find_path(GLES2_INCLUDE_DIR GLES2/gl2.h)
find_path(GBM_INCLUDE_DIR gbm.h)
find_path(DRM_INCLUDE_DIR xf86drm.h)
find_path(DRM_UAPI_INCLUDE_DIR drm.h PATH_SUFFIXES libdrm)
find_library(EGL_LIBRARY EGL)
find_library(GLES2_LIBRARY GLESv2)
find_library(GBM_LIBRARY gbm)
find_library(DRM_LIBRARY drm)
foreach(_v EGL_INCLUDE_DIR GLES2_INCLUDE_DIR GBM_INCLUDE_DIR DRM_INCLUDE_DIR DRM_UAPI_INCLUDE_DIR
           EGL_LIBRARY GLES2_LIBRARY GBM_LIBRARY DRM_LIBRARY)
    if(NOT ${_v})
        message(FATAL_ERROR "milkdrop_renderer needs EGL, GLESv2, GBM and libdrm: ${_v} not found")
    endif()
endforeach()

add_executable(milkdrop_renderer
    src/main.cpp
    src/gl_output.cpp
    src/kms.cpp
    src/visualizer.cpp
)
target_link_libraries(milkdrop_renderer PRIVATE
    milkdrop_core
    libprojectM::projectM
    ${EGL_LIBRARY} ${GLES2_LIBRARY} ${GBM_LIBRARY} ${DRM_LIBRARY}
)
target_include_directories(milkdrop_renderer PRIVATE
    ${EGL_INCLUDE_DIR} ${GLES2_INCLUDE_DIR} ${GBM_INCLUDE_DIR} ${DRM_INCLUDE_DIR} ${DRM_UAPI_INCLUDE_DIR})
if(MILKDROP_GLES2)
    target_compile_definitions(milkdrop_renderer PRIVATE MILKDROP_GLES2)
endif()
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(milkdrop_renderer PRIVATE -Wall -Wextra)
endif()
