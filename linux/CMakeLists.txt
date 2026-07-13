# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "tanuki")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.toonami.tanuki")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(MEDIA_KIT_LINUX_MPV QUIET mpv)
pkg_check_modules(MEDIA_KIT_LINUX_EPOXY QUIET epoxy)

# dart_vlc links with -lvlc, while Debian keeps the unversioned libvlc.so
# symlink in the optional development package. Link through a build-local
# alias to the runtime library that Tanuki actually needs.
find_file(VLC_RUNTIME_LIBRARY
  NAMES libvlc.so.5
  PATHS /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
)
if(VLC_RUNTIME_LIBRARY)
  set(VLC_RUNTIME_LINK_DIR "${CMAKE_BINARY_DIR}/vlc-runtime")
  file(MAKE_DIRECTORY "${VLC_RUNTIME_LINK_DIR}")
  file(CREATE_LINK
    "${VLC_RUNTIME_LIBRARY}"
    "${VLC_RUNTIME_LINK_DIR}/libvlc.so"
    SYMBOLIC
  )
  link_directories("${VLC_RUNTIME_LINK_DIR}")
endif()

function(_media_kit_linux_has_valid_paths result_var prefix)
  set(_valid TRUE)
  foreach(_path IN LISTS ${prefix}_INCLUDE_DIRS)
    if(_path AND NOT EXISTS "${_path}")
      set(_valid FALSE)
    endif()
  endforeach()
  foreach(_path IN LISTS ${prefix}_LIBRARY_DIRS)
    if(_path AND NOT EXISTS "${_path}")
      set(_valid FALSE)
    endif()
  endforeach()
  set(${result_var} "${_valid}" PARENT_SCOPE)
endfunction()

# media_kit is kept for local/non-remote playback paths. Remote series playback
# on Linux uses VLC, so missing mpv development files must not block the build.
set(_media_kit_linux_mpv_valid FALSE)
set(_media_kit_linux_epoxy_valid FALSE)
if(MEDIA_KIT_LINUX_MPV_FOUND)
  _media_kit_linux_has_valid_paths(_media_kit_linux_mpv_valid MEDIA_KIT_LINUX_MPV)
endif()
if(MEDIA_KIT_LINUX_EPOXY_FOUND)
  _media_kit_linux_has_valid_paths(_media_kit_linux_epoxy_valid MEDIA_KIT_LINUX_EPOXY)
endif()

if(MEDIA_KIT_LINUX_MPV_FOUND AND MEDIA_KIT_LINUX_EPOXY_FOUND AND _media_kit_linux_mpv_valid AND _media_kit_linux_epoxy_valid)
  set(MEDIA_KIT_LIBS_AVAILABLE ON CACHE BOOL "Build media_kit with mpv video output on Linux" FORCE)
else()
  set(MEDIA_KIT_LIBS_AVAILABLE OFF CACHE BOOL "Build media_kit with mpv video output on Linux" FORCE)
  message(STATUS "media_kit/mpv development files not available; Linux remote series playback uses VLC")
endif()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# media_kit_video currently trips newer GCC/Clang warnings that are treated as
# errors by this project. Keep the build working by suppressing the specific
# warnings in its plugin target.
if(TARGET media_kit_video_plugin)
  target_compile_options(media_kit_video_plugin PRIVATE
    -Wno-error=conversion-null
    -Wno-error=sign-compare
  )
endif()

# dart_vlc has a warning in its native wrapper with newer GCC/Clang. The app
# still builds with project-wide -Werror, so keep that warning from failing the
# Linux desktop player backend.
if(TARGET dart_vlc_plugin)
  target_compile_options(dart_vlc_plugin PRIVATE
    -Wno-error=delete-incomplete
  )
endif()

# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
