// Linux Bare host. The worklet bundle is embedded at build time.
// Production must not fetch remote JS.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "orbits_bare_spawn.h"
#include "orbits_transport_host.h"

static int looks_remote(const char* url) {
  if (url == NULL || url[0] == '\0') return 0;
  return strncmp(url, "http://", 7) == 0 || strncmp(url, "https://", 8) == 0;
}

int orbits_transport_start(int remote_js, const char* remote_js_url) {
  if (remote_js) return kOrbitsHostRemoteJs;
  if (looks_remote(remote_js_url)) return kOrbitsHostRemoteJs;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_start(OrbitsBareHost* host, int remote_js,
                           const char* remote_js_url, const char* bundle_url,
                           const char* script_url, const char* ipc_version,
                           int require_local_bundle, int local_bundle_present,
                           const char* expected_sha, const char* actual_sha) {
  if (host == NULL) return kOrbitsHostMalformed;
  if (remote_js || looks_remote(remote_js_url) || looks_remote(bundle_url) ||
      looks_remote(script_url)) {
    return kOrbitsHostRemoteJs;  // production Bare must not fetch remote JS
  }
  if (ipc_version != NULL && ipc_version[0] != '\0' &&
      strcmp(ipc_version, "orbits-bare-ipc-v1") != 0) {
    return kOrbitsHostAbiMismatch;
  }
  if (require_local_bundle && !local_bundle_present) {
    return kOrbitsHostBundleMissing;
  }
  if (expected_sha != NULL && actual_sha != NULL && expected_sha[0] != '\0' &&
      actual_sha[0] != '\0' && strcmp(expected_sha, actual_sha) != 0) {
    return kOrbitsHostBundleTampered;
  }
  const int launched = orbits_bare_try_launch(host);
  if (launched != kOrbitsHostOk) {
    return launched;
  }
  host->started = 1;
  return kOrbitsHostOk;
}

int orbits_bare_host_stop(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  orbits_bare_host_kill(host);
  host->started = 0;
  host->suspended = 0;
  host->published = 0;
  return kOrbitsHostOk;
}

static int require_live(const OrbitsBareHost* host) {
  if (host == NULL || !host->started) return kOrbitsHostNotStarted;
  if (host->suspended) return kOrbitsHostSuspended;
  return kOrbitsHostOk;
}

int orbits_bare_host_publish(OrbitsBareHost* host, const char* device_id) {
  if (host == NULL || !host->started) return kOrbitsHostNotStarted;
  if (device_id == NULL || device_id[0] == '\0') return kOrbitsHostMalformed;
  host->published = 1;
  return kOrbitsHostOk;
}

int orbits_bare_host_unpublish(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  host->published = 0;
  return kOrbitsHostOk;
}

int orbits_bare_host_connect(OrbitsBareHost* host) {
  const int live = require_live(host);
  if (live != kOrbitsHostOk) return live;
  return kOrbitsHostBareMissing;
}
int orbits_bare_host_disconnect(OrbitsBareHost* host) {
  const int live = require_live(host);
  if (live != kOrbitsHostOk) return live;
  return kOrbitsHostBareMissing;
}
int orbits_bare_host_refresh_network(OrbitsBareHost* host) {
  const int live = require_live(host);
  if (live != kOrbitsHostOk) return live;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_send(OrbitsBareHost* host, size_t frame_len) {
  const int live = require_live(host);
  if (live != kOrbitsHostOk) return live;
  if (frame_len > 256 * 1024) return kOrbitsHostIpcFrame;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_send_file(OrbitsBareHost* host, const char* path,
                               int64_t size_bytes) {
  const int live = require_live(host);
  if (live != kOrbitsHostOk) return live;
  if (path == NULL || path[0] == '\0') return kOrbitsHostPathRequired;
  if (size_bytes > (int64_t)50 * 1024 * 1024) return kOrbitsHostOversize;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_suspend(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  host->suspended = 1;
  return kOrbitsHostOk;
}

int orbits_bare_host_resume(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  host->suspended = 0;
  return kOrbitsHostOk;
}
