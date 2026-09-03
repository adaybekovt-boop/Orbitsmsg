# The Flutter tooling requires CMake 3.10 or later. Do not raise this
# minimum; older desktop toolchains still consume the plugin.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "orbits_transport_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "orbits_transport_linux_plugin")

add_library(${PLUGIN_NAME} SHARED
  "orbits_transport_plugin.cc"
  "orbits_transport_plugin_registrar.cc"
  "orbits_bare_spawn.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(_orbits_bare_bin "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/orbits-bare/linux-x64/bare")
if(NOT EXISTS "${_orbits_bare_bin}")
  set(_orbits_bare_bin "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/orbits-bare/linux-arm64/bare")
endif()
if(EXISTS "${_orbits_bare_bin}")
  set(orbits_transport_linux_bundled_libraries
    "${_orbits_bare_bin}"
    PARENT_SCOPE
  )
else()
  set(orbits_transport_linux_bundled_libraries
    ""
    PARENT_SCOPE
  )
endif()
