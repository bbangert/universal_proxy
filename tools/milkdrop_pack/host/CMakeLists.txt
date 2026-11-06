# Host helpers for the pack pipeline (never part of the firmware):
#   md_bright  renders a preset off-screen (EGL surfaceless, desktop GL 3.3
#              core, i.e. Mesa llvmpipe on a GPU-less host) with synthetic
#              music and prints its brightness over a frame window;
#   md_seed    LD_PRELOAD shim pinning std::random_device and system_clock
#              so runs are repeatable;
#   md_scale   downscales a JPEG/PNG so its longest side fits a limit.
#
# PROJECTM_SOURCE_DIR is a checkout of the fork at the renderer's pin.
cmake_minimum_required(VERSION 3.21)
project(milkdrop_pack_host LANGUAGES C CXX)

set(PROJECTM_SOURCE_DIR "" CACHE PATH "bbangert/projectm checkout")
if(NOT EXISTS "${PROJECTM_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "set PROJECTM_SOURCE_DIR to a projectM fork checkout")
endif()

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_PLAYLIST OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_PROJECTM_EVAL OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_GLM OFF CACHE BOOL "" FORCE)
set(ENABLE_SDL_UI OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES2 OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_TRANSLATOR_HARNESS OFF CACHE BOOL "" FORCE)
add_subdirectory("${PROJECTM_SOURCE_DIR}" projectm EXCLUDE_FROM_ALL)

find_path(EGL_INCLUDE_DIR EGL/egl.h REQUIRED)
find_library(EGL_LIBRARY EGL REQUIRED)

add_executable(md_bright bright.cpp)
target_compile_features(md_bright PRIVATE cxx_std_17)
target_include_directories(md_bright PRIVATE ${EGL_INCLUDE_DIR} "${PROJECTM_SOURCE_DIR}/vendor/stb_image")
target_link_libraries(md_bright PRIVATE libprojectM::projectM ${EGL_LIBRARY})

add_library(md_seed SHARED seed.cpp)
target_compile_features(md_seed PRIVATE cxx_std_17)

add_executable(md_scale scale.cpp)
target_compile_features(md_scale PRIVATE cxx_std_17)
target_include_directories(md_scale PRIVATE "${PROJECTM_SOURCE_DIR}/vendor/stb_image")
target_link_libraries(md_scale PRIVATE stb_image m)
