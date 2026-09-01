# Linux Bare host. Copies a local `bare` binary into the runner when
# present. Never downloads a runtime or remote JS.

cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "orbits_transport_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "orbits_transport_linux_plugin")

add_library(${PLUGIN_NAME} SHARED
  "orbits_transport_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/bare")
if(NOT EXISTS "${ORBITS_BARE_SLOT}")
  set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tool/bare/linux-x64/bare")
endif()

set(orbits_transport_linux_bundled_libraries "")
if(EXISTS "${ORBITS_BARE_SLOT}")
  list(APPEND orbits_transport_linux_bundled_libraries "${ORBITS_BARE_SLOT}")
endif()
set(orbits_transport_linux_bundled_libraries ${orbits_transport_linux_bundled_libraries} PARENT_SCOPE)
