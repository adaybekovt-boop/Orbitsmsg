// Linux Bare host. The worklet bundle is embedded at build time.
// Production must not fetch remote JS.

#include <string.h>

int orbits_transport_start(int remote_js, const char* remote_js_url) {
  if (remote_js) return -1;
  if (remote_js_url != NULL && remote_js_url[0] != '\0') return -1;
  return 0;
}
