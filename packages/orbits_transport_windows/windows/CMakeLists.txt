# Windows Bare host. Bundles a local bare.exe when present. Never downloads.

cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "orbits_transport_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "orbits_transport_windows_plugin")

add_library(${PLUGIN_NAME} SHARED
  "orbits_transport_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/bare.exe")
if(NOT EXISTS "${ORBITS_BARE_SLOT}")
  set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tool/bare/windows-x64/bare.exe")
endif()

set(orbits_transport_windows_bundled_libraries "")
if(EXISTS "${ORBITS_BARE_SLOT}")
  list(APPEND orbits_transport_windows_bundled_libraries "${ORBITS_BARE_SLOT}")
endif()
set(orbits_transport_windows_bundled_libraries ${orbits_transport_windows_bundled_libraries} PARENT_SCOPE)
