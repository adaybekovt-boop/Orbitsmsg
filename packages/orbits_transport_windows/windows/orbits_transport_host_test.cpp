#include <stdio.h>
#include <string.h>

#include "orbits_transport_host.h"

static int fail(const char* message) {
  fprintf(stderr, "orbits_transport_host_test: %s\n", message);
  return 1;
}

int main() {
  OrbitsBareHost host;
  memset(&host, 0, sizeof(host));

  if (orbits_bare_host_start(&host, true, "", "", "", "orbits-bare-ipc-v1",
                             false, false, "", "") != kOrbitsHostRemoteJs) {
    return fail("remote JS must be rejected");
  }
  if (host.started) {
    return fail("remote JS must not mark the host started");
  }

  if (orbits_bare_host_start(&host, false, "", "", "", "orbits-bare-ipc-v1",
                             false, false, "", "") != kOrbitsHostBareMissing) {
    return fail("missing Bare must fail closed");
  }
  if (host.started) {
    return fail("missing Bare must not mark the host started");
  }
  if (orbits_bare_host_connect(&host) != kOrbitsHostNotStarted) {
    return fail("connect without start must fail");
  }
  if (orbits_bare_host_send(&host, 4) != kOrbitsHostNotStarted) {
    return fail("send without start must fail");
  }
  if (orbits_bare_host_send_file(&host, "/tmp/a.bin", 12) !=
      kOrbitsHostNotStarted) {
    return fail("sendFile without start must fail");
  }
  return 0;
}
