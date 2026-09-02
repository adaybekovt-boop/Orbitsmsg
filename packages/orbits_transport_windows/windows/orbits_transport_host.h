#ifndef ORBITS_TRANSPORT_WINDOWS_HOST_H_
#define ORBITS_TRANSPORT_WINDOWS_HOST_H_

#include <stddef.h>
#include <stdint.h>

enum OrbitsHostCode {
  kOrbitsHostOk = 0,
  kOrbitsHostRemoteJs = -1,
  kOrbitsHostNotStarted = -2,
  kOrbitsHostSuspended = -3,
  kOrbitsHostIpcFrame = -4,
  kOrbitsHostPathRequired = -5,
  kOrbitsHostOversize = -6,
  kOrbitsHostBundleMissing = -7,
  kOrbitsHostBundleTampered = -8,
  kOrbitsHostAbiMismatch = -9,
  kOrbitsHostMalformed = -10,
  kOrbitsHostBareMissing = -11,
};

struct OrbitsBareHost {
  bool started;
  bool suspended;
  bool published;
};

int orbits_transport_start(bool remote_js, const char* remote_js_url);
int orbits_bare_host_start(OrbitsBareHost* host, bool remote_js,
                           const char* remote_js_url, const char* bundle_url,
                           const char* script_url, const char* ipc_version,
                           bool require_local_bundle, bool local_bundle_present,
                           const char* expected_sha, const char* actual_sha);
int orbits_bare_host_stop(OrbitsBareHost* host);
int orbits_bare_host_publish(OrbitsBareHost* host, const char* device_id);
int orbits_bare_host_unpublish(OrbitsBareHost* host);
int orbits_bare_host_connect(OrbitsBareHost* host);
int orbits_bare_host_disconnect(OrbitsBareHost* host);
int orbits_bare_host_refresh_network(OrbitsBareHost* host);
int orbits_bare_host_send(OrbitsBareHost* host, size_t frame_len);
int orbits_bare_host_send_file(OrbitsBareHost* host, const char* path,
                               int64_t size_bytes);
int orbits_bare_host_suspend(OrbitsBareHost* host);
int orbits_bare_host_resume(OrbitsBareHost* host);

#endif  // ORBITS_TRANSPORT_WINDOWS_HOST_H_
