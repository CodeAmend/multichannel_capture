# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multichannel_capture_library VERSION 0.0.1 LANGUAGES C)

add_library(multichannel_capture SHARED
  "multichannel_capture.c"
)

set_target_properties(multichannel_capture PROPERTIES
  PUBLIC_HEADER multichannel_capture.h
  OUTPUT_NAME "multichannel_capture"
)

target_compile_definitions(multichannel_capture PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(multichannel_capture PRIVATE "-Wl,-z,max-page-size=16384")
endif()
