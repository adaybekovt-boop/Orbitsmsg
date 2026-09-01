// Windows Bare host. The worklet bundle is embedded at build time.
// Production must not fetch remote JS.

#include <string>

static bool rejects_remote_js(bool remote_js, const std::string& remote_js_url) {
  return remote_js || !remote_js_url.empty();
}

// Bare binary is not linked in this tree yet. The host still refuses
// remote executable JS before any spawn is attempted.
int orbits_transport_start(bool remote_js, const char* remote_js_url) {
  const std::string url = remote_js_url ? remote_js_url : "";
  if (rejects_remote_js(remote_js, url)) {
    return -1; // production Bare must not fetch remote JS
  }
  return 0;
}
