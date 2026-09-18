#!/usr/bin/env bash
# Prove official BareKit symbols and start a worklet from the verified extract.
# Android Worklet.start is the packaged host API. linux/x64 libbare-kit.so is
# the same prebuilds.zip and exposes official bare_worklet_* entry points.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE="${ORBITS_BARE_CACHE:-$ROOT/build/orbits-bare}"
KIT="$CACHE/bare-kit"
JAR="$KIT/android/bare-kit/classes.jar"
ANDROID_SO="$KIT/android/bare-kit/jni/arm64-v8a/libbare-kit.so"
LINUX_SO="$KIT/linux/x64/libbare-kit.so"
WORKLET="$ROOT/tool/connectivity_harness/src/worklet.js"

if [[ ! -f "$JAR" ]]; then
  echo "BARE_RUNTIME_MISSING: $JAR" >&2
  exit 1
fi
if [[ ! -f "$ANDROID_SO" ]]; then
  echo "BARE_RUNTIME_MISSING: $ANDROID_SO" >&2
  exit 1
fi
if [[ ! -f "$WORKLET" ]]; then
  echo "BARE_RUNTIME_MISSING: $WORKLET" >&2
  exit 1
fi

javap -public -classpath "$JAR" to.holepunch.bare.kit.Worklet \
  | grep -F -q 'start(java.lang.String, java.lang.String, java.nio.charset.Charset, java.lang.String[])'
echo "ok official Worklet.start(String, String, Charset, String[])"

android_syms="$(nm -D "$ANDROID_SO")"
grep -q 'Java_to_holepunch_bare_kit_Worklet_start' <<<"$android_syms"
echo "ok android JNI Java_to_holepunch_bare_kit_Worklet_start"

if [[ ! -f "$LINUX_SO" ]]; then
  echo "BARE_RUNTIME_MISSING: $LINUX_SO (extract linux/x64 from the same zip)" >&2
  exit 1
fi
linux_syms="$(nm -D "$LINUX_SO")"
grep -q 'bare_worklet_start' <<<"$linux_syms"
echo "ok linux libbare-kit.so exports bare_worklet_start"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "skip official bare_worklet_start probe on $(uname -s) (linux/x64 .so)"
  exit 0
fi

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orbits-barekit-start.XXXXXX")"
PROBE_SRC="$PROBE_DIR/kit_start.c"
PROBE_BIN="$PROBE_DIR/kit_start"
cleanup() {
  rm -rf "$PROBE_DIR"
}
trap cleanup EXIT

cat > "$PROBE_SRC" <<'C'
/* Official bare-kit 2.4.3 C entry points from shared/worklet.h.
   The worklet object is allocated by the library (opaque). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  size_t memory_limit;
  const char *assets;
} bare_worklet_options_t;

typedef struct {
  char *base;
  size_t len;
} uv_buf_t;

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: kit-start <libbare-kit.so> <worklet.js>\n");
    return 2;
  }
  void *lib = dlopen(argv[1], RTLD_NOW);
  if (!lib) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    return 1;
  }
  int (*alloc_fn)(void **) = dlsym(lib, "bare_worklet_alloc");
  int (*init_fn)(void *, const bare_worklet_options_t *) = dlsym(lib, "bare_worklet_init");
  int (*start_fn)(void *, const char *, const uv_buf_t *, int, const char **) =
      dlsym(lib, "bare_worklet_start");
  int (*term_fn)(void *) = dlsym(lib, "bare_worklet_terminate");
  void (*destroy_fn)(void *) = dlsym(lib, "bare_worklet_destroy");
  if (!alloc_fn || !init_fn || !start_fn || !term_fn || !destroy_fn) {
    fprintf(stderr, "missing official bare_worklet_* symbols\n");
    return 1;
  }
  FILE *fh = fopen(argv[2], "rb");
  if (!fh) {
    perror(argv[2]);
    return 1;
  }
  if (fseek(fh, 0, SEEK_END) != 0) {
    perror("fseek");
    return 1;
  }
  long n = ftell(fh);
  if (n <= 0) {
    fprintf(stderr, "empty worklet\n");
    return 1;
  }
  rewind(fh);
  char *source = malloc((size_t)n);
  if (!source || fread(source, 1, (size_t)n, fh) != (size_t)n) {
    fprintf(stderr, "read worklet failed\n");
    return 1;
  }
  fclose(fh);

  void *worklet = NULL;
  int e = alloc_fn(&worklet);
  if (e != 0 || worklet == NULL) {
    fprintf(stderr, "bare_worklet_alloc rc=%d\n", e);
    return 1;
  }
  bare_worklet_options_t options;
  options.memory_limit = 24u * 1024u * 1024u;
  options.assets = NULL;
  e = init_fn(worklet, &options);
  if (e != 0) {
    fprintf(stderr, "bare_worklet_init rc=%d\n", e);
    return 1;
  }
  uv_buf_t buf;
  buf.base = source;
  buf.len = (size_t)n;
  e = start_fn(worklet, "/orbits/worklet.js", &buf, 0, NULL);
  if (e != 0) {
    fprintf(stderr, "bare_worklet_start rc=%d\n", e);
    return 1;
  }
  term_fn(worklet);
  destroy_fn(worklet);
  free(source);
  printf("ok official bare_worklet_start of /orbits/worklet.js\n");
  return 0;
}
C

cc -O2 -Wall -Werror "$PROBE_SRC" -ldl -o "$PROBE_BIN"
"$PROBE_BIN" "$LINUX_SO" "$WORKLET"
