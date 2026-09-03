// Official Holepunch bare-runtime spawn + orbits-bare-ipc-v1.
// Paths and hashes only. This file must not embed a remote URL.

#include "orbits_bare_spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "orbits_sha256.h"

static int file_exists(const char* path) {
  struct stat st;
  return path && path[0] && stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static int read_hex_sidecar(const char* binary, char* hex, size_t hex_len) {
  char side[4096];
  snprintf(side, sizeof(side), "%s.sha256", binary);
  FILE* fp = fopen(side, "r");
  if (fp == NULL) return 0;
  if (fgets(hex, (int)hex_len, fp) == NULL) {
    fclose(fp);
    return 0;
  }
  fclose(fp);
  char* nl = strchr(hex, '\n');
  if (nl) *nl = '\0';
  char* sp = strchr(hex, ' ');
  if (sp) *sp = '\0';
  return (int)strlen(hex) == 64;
}

static int copy_if_file(const char* path, char* out, size_t out_len) {
  if (!file_exists(path)) return 0;
  snprintf(out, out_len, "%s", path);
  return 1;
}

static int exe_dir(char* out, size_t out_len) {
  char exe[4096];
  const ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return 0;
  exe[n] = '\0';
  char* slash = strrchr(exe, '/');
  if (slash == NULL) return 0;
  slash[1] = '\0';
  snprintf(out, out_len, "%s", exe);
  return 1;
}

int orbits_bare_find_runtime(char* out, size_t out_len) {
  const char* env = getenv("ORBITS_BARE_RUNTIME");
  if (env && env[0] == '/' && file_exists(env)) {
    snprintf(out, out_len, "%s", env);
    return 1;
  }
  char dir[4096];
  if (!exe_dir(dir, sizeof(dir))) return 0;
  char cand[5120];
  snprintf(cand, sizeof(cand), "%sbare", dir);
  if (copy_if_file(cand, out, out_len)) return 1;
  snprintf(cand, sizeof(cand), "%slib/bare", dir);
  if (copy_if_file(cand, out, out_len)) return 1;
  return 0;
}

int orbits_bare_find_worklet(char* out, size_t out_len) {
  const char* env = getenv("ORBITS_WORKLET_JS");
  if (env && env[0] == '/' && file_exists(env)) {
    snprintf(out, out_len, "%s", env);
    return 1;
  }
  if (file_exists("tool/connectivity_harness/src/worklet.js")) {
    snprintf(out, out_len, "%s", "tool/connectivity_harness/src/worklet.js");
    return 1;
  }
  char dir[4096];
  if (!exe_dir(dir, sizeof(dir))) return 0;
  char cand[5120];
  snprintf(cand, sizeof(cand), "%sdata/orbits-worklet/src/worklet.js", dir);
  if (copy_if_file(cand, out, out_len)) return 1;
  snprintf(
      cand, sizeof(cand),
      "%sdata/flutter_assets/tool/connectivity_harness/src/worklet.js", dir);
  if (copy_if_file(cand, out, out_len)) return 1;
  return 0;
}

int orbits_bare_verify_sha256_file(const char* path, const char* expected_hex) {
  FILE* fp = fopen(path, "rb");
  if (fp == NULL) return 0;
  orbits_sha256_ctx ctx;
  orbits_sha256_init(&ctx);
  unsigned char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
    orbits_sha256_update(&ctx, buf, n);
  }
  fclose(fp);
  unsigned char digest[32];
  orbits_sha256_final(&ctx, digest);
  char hex[65];
  orbits_sha256_hex(digest, hex);
  if (expected_hex == NULL || expected_hex[0] == '\0') return 0;
  return strcmp(hex, expected_hex) == 0;
}

static int close_pair(int fd[2]) {
  close(fd[0]);
  close(fd[1]);
  return -1;
}

int orbits_bare_try_launch(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  char runtime[4096];
  char worklet[4096];
  if (!orbits_bare_find_runtime(runtime, sizeof(runtime))) {
    return kOrbitsHostBareMissing;
  }
  char expected[80];
  if (!read_hex_sidecar(runtime, expected, sizeof(expected))) {
    return kOrbitsHostRuntimeTampered;
  }
  if (!orbits_bare_verify_sha256_file(runtime, expected)) {
    return kOrbitsHostRuntimeTampered;
  }
  if (!orbits_bare_find_worklet(worklet, sizeof(worklet))) {
    return kOrbitsHostBundleMissing;
  }
  int in_pipe[2];
  int out_pipe[2];
  if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) {
    return kOrbitsHostBareMissing;
  }
  pid_t pid = fork();
  if (pid < 0) {
    close_pair(in_pipe);
    close_pair(out_pipe);
    return kOrbitsHostBareMissing;
  }
  if (pid == 0) {
    dup2(in_pipe[0], STDIN_FILENO);
    dup2(out_pipe[1], STDOUT_FILENO);
    close(in_pipe[0]);
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(out_pipe[1]);
    const char* backend = getenv("ORBITS_HARNESS_BACKEND");
    if (backend == NULL) backend = "loopback";
    setenv("ORBITS_HARNESS_BACKEND", backend, 0);
    setenv("ORBITS_RUNTIME", "bare", 1);
    char* argv[] = {runtime, worklet, NULL};
    execv(runtime, argv);
    _exit(127);
  }
  close(in_pipe[0]);
  close(out_pipe[1]);
  host->child_pid = (int)pid;
  host->stdin_fd = in_pipe[1];
  host->stdout_fd = out_pipe[0];
  return kOrbitsHostOk;
}

int orbits_bare_host_kill(OrbitsBareHost* host) {
  if (host == NULL) return kOrbitsHostMalformed;
  if (host->stdin_fd > 0) {
    close(host->stdin_fd);
    host->stdin_fd = 0;
  }
  if (host->stdout_fd > 0) {
    close(host->stdout_fd);
    host->stdout_fd = 0;
  }
  if (host->child_pid > 0) {
    kill((pid_t)host->child_pid, SIGTERM);
    int status = 0;
    waitpid((pid_t)host->child_pid, &status, 0);
    host->child_pid = 0;
  }
  return kOrbitsHostOk;
}
