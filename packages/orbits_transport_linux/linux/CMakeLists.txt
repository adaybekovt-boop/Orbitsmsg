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
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CMAKE_DL_LIBS})

# Prefer the matching CPU slot. `bare` is the host-arch copy from embed.sh
# (linux-x64 on amd64 CI). `bare-arm64` is vendored beside it and must not
# overwrite the runnable host binary. Never downloads.
# CMAKE_CURRENT_SOURCE_DIR is packages/orbits_transport_linux/linux — three
# parents reach the repo root (not four).
set(_PLUGIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(_TOOL_BARE_X64 "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/bare/linux-x64/bare")
set(_TOOL_BARE_ARM64 "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/bare/linux-arm64/bare")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64|arm64")
  if(EXISTS "${_PLUGIN_DIR}/bare-arm64")
    set(ORBITS_BARE_SLOT "${_PLUGIN_DIR}/bare-arm64")
  elseif(EXISTS "${_PLUGIN_DIR}/bare")
    set(ORBITS_BARE_SLOT "${_PLUGIN_DIR}/bare")
  else()
    set(ORBITS_BARE_SLOT "${_TOOL_BARE_ARM64}")
  endif()
else()
  if(EXISTS "${_PLUGIN_DIR}/bare")
    set(ORBITS_BARE_SLOT "${_PLUGIN_DIR}/bare")
  else()
    set(ORBITS_BARE_SLOT "${_TOOL_BARE_X64}")
  endif()
endif()

# Always install as `bare` so the host (dladdr / lib/bare) finds it even
# when the source slot was named bare-arm64.
set(orbits_transport_linux_bundled_libraries "")
if(EXISTS "${ORBITS_BARE_SLOT}")
  set(_ORBITS_BARE_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/bare")
  configure_file("${ORBITS_BARE_SLOT}" "${_ORBITS_BARE_BUNDLE}" COPYONLY)
  execute_process(COMMAND chmod +x "${_ORBITS_BARE_BUNDLE}" ERROR_QUIET)
  list(APPEND orbits_transport_linux_bundled_libraries "${_ORBITS_BARE_BUNDLE}")
endif()
set(_STDLIB_ZIP "${_PLUGIN_DIR}/bare_stdlib.zip")
if(NOT EXISTS "${_STDLIB_ZIP}")
  set(_STDLIB_ZIP "${CMAKE_CURRENT_SOURCE_DIR}/../../../tool/connectivity_harness/bare_stdlib.zip")
endif()
if(EXISTS "${_STDLIB_ZIP}")
  set(_STDLIB_BUNDLE "${CMAKE_CURRENT_BINARY_DIR}/bare_stdlib.zip")
  configure_file("${_STDLIB_ZIP}" "${_STDLIB_BUNDLE}" COPYONLY)
  list(APPEND orbits_transport_linux_bundled_libraries "${_STDLIB_BUNDLE}")
endif()
set(orbits_transport_linux_bundled_libraries ${orbits_transport_linux_bundled_libraries} PARENT_SCOPE)
