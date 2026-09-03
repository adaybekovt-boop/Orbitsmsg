# The Flutter tooling requires CMake 3.14 or later. Do not raise this
# minimum; older Visual Studio generators still consume the plugin.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "orbits_transport_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "orbits_transport_windows_plugin")

add_library(${PLUGIN_NAME} SHARED
  "include/orbits_transport_windows/orbits_transport_plugin.h"
  "orbits_transport_host.h"
  "orbits_transport_plugin.cpp"
  "orbits_transport_plugin_registrar.cpp"
  "orbits_bare_spawn.cpp"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set(_orbits_bare_bin "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/orbits-bare/win32-x64/bare.exe")
if(NOT EXISTS "${_orbits_bare_bin}")
  set(_orbits_bare_bin "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/orbits-bare/win32-arm64/bare.exe")
endif()
if(EXISTS "${_orbits_bare_bin}" AND EXISTS "${_orbits_bare_bin}.sha256")
  set(orbits_transport_windows_bundled_libraries
    "${_orbits_bare_bin}"
    "${_orbits_bare_bin}.sha256"
    PARENT_SCOPE
  )
else()
  set(orbits_transport_windows_bundled_libraries
    ""
    PARENT_SCOPE
  )
endif()
