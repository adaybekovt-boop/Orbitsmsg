#ifndef ORBITS_TRANSPORT_LINUX_BARE_SPAWN_H_
#define ORBITS_TRANSPORT_LINUX_BARE_SPAWN_H_

#include <stddef.h>

#include "orbits_transport_host.h"

int orbits_bare_find_runtime(char* out, size_t out_len);
int orbits_bare_find_worklet(char* out, size_t out_len);
int orbits_bare_verify_sha256_file(const char* path, const char* expected_hex);
int orbits_bare_try_launch(OrbitsBareHost* host);
int orbits_bare_host_kill(OrbitsBareHost* host);

#endif  // ORBITS_TRANSPORT_LINUX_BARE_SPAWN_H_
