// Windows Bare host. The worklet bundle is embedded at build time.
// Production must not fetch remote JS.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "orbits_bare_spawn.h"
#include "orbits_transport_host.h"

static bool looks_remote(const char* url) {
  if (url == nullptr || url[0] == '\0') return false;
  return strncmp(url, "http://", 7) == 0 || strncmp(url, "https://", 8) == 0;
}

static bool rejects_remote_js(bool remote_js, const char* remote_js_url,
                              const char* bundle_url, const char* script_url) {
  return remote_js || looks_remote(remote_js_url) || looks_remote(bundle_url) ||
         looks_remote(script_url);
}

int orbits_transport_start(bool remote_js, const char* remote_js_url) {
  if (rejects_remote_js(remote_js, remote_js_url, nullptr, nullptr)) {
    return kOrbitsHostRemoteJs;  // production Bare must not fetch remote JS
  }
  return kOrbitsHostBareMissing;  // linked Bare runtime is not shipped
}

int orbits_bare_host_start(OrbitsBareHost* host, bool remote_js,
                           const char* remote_js_url, const char* bundle_url,
                           const char* script_url, const char* ipc_version,
                           bool require_local_bundle, bool local_bundle_present,
                           const char* expected_sha, const char* actual_sha) {
  if (host == nullptr) return kOrbitsHostMalformed;
  if (rejects_remote_js(remote_js, remote_js_url, bundle_url, script_url)) {
    return kOrbitsHostRemoteJs;  // production Bare must not fetch remote JS
  }
  if (ipc_version != nullptr && ipc_version[0] != '\0' &&
      strcmp(ipc_version, "orbits-bare-ipc-v1") != 0) {
    return kOrbitsHostAbiMismatch;
  }
  if (require_local_bundle && !local_bundle_present) {
    return kOrbitsHostBundleMissing;
  }
  if (expected_sha != nullptr && actual_sha != nullptr &&
      expected_sha[0] != '\0' && actual_sha[0] != '\0' &&
      strcmp(expected_sha, actual_sha) != 0) {
    return kOrbitsHostBundleTampered;
  }
  const int launched = orbits_bare_try_launch(host);
  if (launched != kOrbitsHostOk) {
    return launched;
  }
  host->started = true;
  return kOrbitsHostOk;
}

int orbits_bare_host_stop(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  orbits_bare_host_kill(host);
  host->started = false;
  host->suspended = false;
  host->published = false;
  return kOrbitsHostOk;
}

static int require_live(const OrbitsBareHost* host) {
  if (host == nullptr || !host->started) return kOrbitsHostNotStarted;
  if (host->suspended) return kOrbitsHostSuspended;
  return kOrbitsHostOk;
}

int orbits_bare_host_publish(OrbitsBareHost* host, const char* device_id) {
  if (host == nullptr || !host->started) return kOrbitsHostNotStarted;
  if (device_id == nullptr || device_id[0] == '\0') return kOrbitsHostMalformed;
  host->published = true;
  return kOrbitsHostOk;
}

int orbits_bare_host_unpublish(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  host->published = false;
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
  if (path == nullptr || path[0] == '\0') return kOrbitsHostPathRequired;
  if (size_bytes > 50LL * 1024 * 1024) return kOrbitsHostOversize;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_suspend(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  host->suspended = true;
  return kOrbitsHostOk;
}

int orbits_bare_host_resume(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  host->suspended = false;
  return kOrbitsHostOk;
}
