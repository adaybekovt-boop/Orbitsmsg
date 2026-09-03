#include "orbits_bare_spawn.h"

#ifdef _WIN32
#include <windows.h>
#endif

#include <stdio.h>
#include <string.h>

#ifdef _WIN32
static bool file_exists(const char* path) {
  DWORD attrs = GetFileAttributesA(path);
  return attrs != INVALID_FILE_ATTRIBUTES &&
         !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static bool read_sidecar(const char* binary, char* hex, size_t hex_len) {
  char side[4096];
  snprintf(side, sizeof(side), "%s.sha256", binary);
  FILE* fp = fopen(side, "r");
  if (!fp) return false;
  if (!fgets(hex, (int)hex_len, fp)) {
    fclose(fp);
    return false;
  }
  fclose(fp);
  char* nl = strchr(hex, '\n');
  if (nl) *nl = '\0';
  return strlen(hex) == 64;
}

static bool module_dir(char* out, size_t out_len) {
  char exe[MAX_PATH];
  const DWORD n = GetModuleFileNameA(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return false;
  char* slash = strrchr(exe, '\\');
  if (slash == nullptr) slash = strrchr(exe, '/');
  if (slash == nullptr) return false;
  slash[1] = '\0';
  snprintf(out, out_len, "%s", exe);
  return true;
}

int orbits_bare_try_launch(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  const char* env = getenv("ORBITS_BARE_RUNTIME");
  char runtime[4096] = {0};
  if (env && env[0] && file_exists(env)) {
    snprintf(runtime, sizeof(runtime), "%s", env);
  } else {
    char dir[4096] = {0};
    char cand[4096] = {0};
    if (module_dir(dir, sizeof(dir))) {
      snprintf(cand, sizeof(cand), "%sbare.exe", dir);
      if (file_exists(cand)) {
        snprintf(runtime, sizeof(runtime), "%s", cand);
      } else {
        snprintf(cand, sizeof(cand), "%slib\\bare.exe", dir);
        if (file_exists(cand)) {
          snprintf(runtime, sizeof(runtime), "%s", cand);
        }
      }
    }
    if (runtime[0] == '\0') return kOrbitsHostBareMissing;
  }
  char expected[80];
  if (!read_sidecar(runtime, expected, sizeof(expected))) {
    return kOrbitsHostRuntimeTampered;
  }
  char worklet_buf[4096] = {0};
  const char* worklet = getenv("ORBITS_WORKLET_JS");
  if (worklet == nullptr || worklet[0] == '\0') {
    if (file_exists("tool/connectivity_harness/src/worklet.js")) {
      worklet = "tool/connectivity_harness/src/worklet.js";
    } else {
      char dir[4096] = {0};
      if (module_dir(dir, sizeof(dir))) {
        snprintf(worklet_buf, sizeof(worklet_buf),
                 "%sdata\\orbits-worklet\\src\\worklet.js", dir);
        if (file_exists(worklet_buf)) worklet = worklet_buf;
      }
    }
  }
  if (worklet == nullptr || worklet[0] == '\0') {
    return kOrbitsHostBundleMissing;
  }
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  ZeroMemory(&pi, sizeof(pi));
  char cmd[8192];
  snprintf(cmd, sizeof(cmd), "\"%s\" \"%s\"", runtime, worklet);
  if (!CreateProcessA(nullptr, cmd, nullptr, nullptr, FALSE, 0, nullptr,
                      nullptr, &si, &pi)) {
    return kOrbitsHostBareMissing;
  }
  host->child_pid = (int)pi.dwProcessId;
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return kOrbitsHostOk;
}

int orbits_bare_host_kill(OrbitsBareHost* host) {
  if (host == nullptr) return kOrbitsHostMalformed;
  if (host->child_pid > 0) {
    HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)host->child_pid);
    if (proc) {
      TerminateProcess(proc, 1);
      CloseHandle(proc);
    }
    host->child_pid = 0;
  }
  return kOrbitsHostOk;
}
#else
int orbits_bare_try_launch(OrbitsBareHost* host) {
  (void)host;
  return kOrbitsHostBareMissing;
}

int orbits_bare_host_kill(OrbitsBareHost* host) {
  (void)host;
  return kOrbitsHostOk;
}
#endif
