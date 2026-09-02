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

# CMAKE_CURRENT_SOURCE_DIR is packages/orbits_transport_windows/windows —
# three parents reach the repo root (not four). Never downloads.
set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/bare.exe")
if(NOT EXISTS "${ORBITS_BARE_SLOT}")
  set(ORBITS_BARE_SLOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/bare/windows-x64/bare.exe")
endif()

set(orbits_transport_windows_bundled_libraries "")
if(EXISTS "${ORBITS_BARE_SLOT}")
  set(_ORBITS_BARE_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/bare.exe")
  configure_file("${ORBITS_BARE_SLOT}" "${_ORBITS_BARE_BUNDLE}" COPYONLY)
  list(APPEND orbits_transport_windows_bundled_libraries "${_ORBITS_BARE_BUNDLE}")
endif()
set(_STDLIB_ZIP "${CMAKE_CURRENT_SOURCE_DIR}/bare_stdlib.zip")
if(NOT EXISTS "${_STDLIB_ZIP}")
  set(_STDLIB_ZIP "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/connectivity_harness/bare_stdlib.zip")
endif()
if(EXISTS "${_STDLIB_ZIP}")
  set(_STDLIB_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/bare_stdlib.zip")
  configure_file("${_STDLIB_ZIP}" "${_STDLIB_BUNDLE}" COPYONLY)
  list(APPEND orbits_transport_windows_bundled_libraries "${_STDLIB_BUNDLE}")
endif()
# Optional local Corestore addon next to the host. Never downloads.
set(_CORESTORE_ADDON "")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/corestore.bare")
  set(_CORESTORE_ADDON "${CMAKE_CURRENT_SOURCE_DIR}/corestore.bare")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/addons/corestore.bare")
  set(_CORESTORE_ADDON "${CMAKE_CURRENT_SOURCE_DIR}/addons/corestore.bare")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/bare/addons/corestore.bare")
  set(_CORESTORE_ADDON "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/bare/addons/corestore.bare")
endif()
if(_CORESTORE_ADDON)
  set(_CORESTORE_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/corestore.bare")
  configure_file("${_CORESTORE_ADDON}" "${_CORESTORE_BUNDLE}" COPYONLY)
  list(APPEND orbits_transport_windows_bundled_libraries "${_CORESTORE_BUNDLE}")
endif()
set(orbits_transport_windows_bundled_libraries ${orbits_transport_windows_bundled_libraries} PARENT_SCOPE)
