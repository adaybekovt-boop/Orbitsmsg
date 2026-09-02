// Linux Bare host. Registers a Flutter plugin, refuses remote JS, and
// reports a local bundled Bare path when present. Never downloads.

#include "include/orbits_transport_linux/orbits_transport_plugin.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <string.h>
#include <unistd.h>

#define ORBITS_TRANSPORT_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), orbits_transport_plugin_get_type(), \
                              OrbitsTransportPlugin))

struct _OrbitsTransportPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(OrbitsTransportPlugin, orbits_transport_plugin,
              g_object_get_type())

static gchar* dirname_of(const gchar* path) {
  if (path == NULL || path[0] == '\0') return NULL;
  gchar* copy = g_strdup(path);
  gchar* slash = strrchr(copy, '/');
  if (slash == NULL) {
    g_free(copy);
    return g_strdup(".");
  }
  if (slash == copy) {
    slash[1] = '\0';
    return copy;
  }
  *slash = '\0';
  return copy;
}

static gboolean file_is_executable(const gchar* path) {
  return path != NULL && access(path, X_OK) == 0;
}

static gboolean string_has_scheme(const gchar* s) {
  return s != NULL && strstr(s, "://") != NULL;
}

static gboolean fl_value_contains_scheme(FlValue* value, GHashTable* seen) {
  if (value == NULL) return FALSE;
  FlValueType type = fl_value_get_type(value);
  if (type == FL_VALUE_TYPE_STRING) {
    return string_has_scheme(fl_value_get_string(value));
  }
  if (type != FL_VALUE_TYPE_MAP && type != FL_VALUE_TYPE_LIST) {
    return FALSE;
  }
  if (g_hash_table_contains(seen, value)) return FALSE;
  g_hash_table_insert(seen, value, value);
  const gsize n = fl_value_get_length(value);
  for (gsize i = 0; i < n; i++) {
    FlValue* child = type == FL_VALUE_TYPE_MAP
                         ? fl_value_get_map_value(value, i)
                         : fl_value_get_list_value(value, i);
    if (fl_value_contains_scheme(child, seen)) return TRUE;
  }
  return FALSE;
}

static gboolean start_config_wants_remote_js(FlValue* args) {
  if (args == NULL || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  FlValue* flag = fl_value_lookup_string(args, "remoteJs");
  if (flag != NULL && fl_value_get_type(flag) == FL_VALUE_TYPE_BOOL &&
      fl_value_get_bool(flag)) {
    return TRUE;
  }
  const gchar* remote_keys[] = {"remoteJsUrl", "bundleUrl",  "scriptUrl",
                                "addonUrl",    "downloadUrl", "moduleUrl",
                                "jsUrl",       "workletUrl",  NULL};
  for (int i = 0; remote_keys[i] != NULL; i++) {
    FlValue* v = fl_value_lookup_string(args, remote_keys[i]);
    if (v != NULL && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
      const gchar* s = fl_value_get_string(v);
      if (s != NULL && s[0] != '\0') return TRUE;
    }
  }
  GHashTable* seen = g_hash_table_new(g_direct_hash, g_direct_equal);
  const gboolean remote = fl_value_contains_scheme(args, seen);
  g_hash_table_unref(seen);
  return remote;
}

// Look next to this .so (Flutter bundled_libraries) then next to the exe.
static gchar* bundled_bare_path() {
  Dl_info info;
  memset(&info, 0, sizeof(info));
  if (dladdr((void*)orbits_transport_plugin_register_with_registrar, &info) &&
      info.dli_fname != NULL) {
    gchar* dir = dirname_of(info.dli_fname);
    if (dir != NULL) {
      gchar* candidate = g_build_filename(dir, "bare", NULL);
      gchar* candidate_arm = g_build_filename(dir, "bare-arm64", NULL);
      g_free(dir);
      if (file_is_executable(candidate)) {
        g_free(candidate_arm);
        return candidate;
      }
      g_free(candidate);
      if (file_is_executable(candidate_arm)) return candidate_arm;
      g_free(candidate_arm);
    }
  }
  gchar* exe = g_file_read_link("/proc/self/exe", NULL);
  if (exe != NULL) {
    gchar* dir = dirname_of(exe);
    g_free(exe);
    if (dir != NULL) {
      gchar* candidate = g_build_filename(dir, "bare", NULL);
      gchar* lib_candidate = g_build_filename(dir, "lib", "bare", NULL);
      g_free(dir);
      if (file_is_executable(candidate)) {
        g_free(lib_candidate);
        return candidate;
      }
      g_free(candidate);
      if (file_is_executable(lib_candidate)) return lib_candidate;
      g_free(lib_candidate);
    }
  }
  return NULL;
}

static void orbits_transport_plugin_handle_method_call(
    OrbitsTransportPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "start") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (start_config_wants_remote_js(args)) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "REMOTE_JS", "production Bare must not fetch remote JS", nullptr));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "stop") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "barePath") == 0) {
    gchar* path = bundled_bare_path();
    if (path == NULL) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      g_autoptr(FlValue) value = fl_value_new_string(path);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
      g_free(path);
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void orbits_transport_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(orbits_transport_plugin_parent_class)->dispose(object);
}

static void orbits_transport_plugin_class_init(
    OrbitsTransportPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = orbits_transport_plugin_dispose;
}

static void orbits_transport_plugin_init(OrbitsTransportPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  OrbitsTransportPlugin* plugin = ORBITS_TRANSPORT_PLUGIN(user_data);
  orbits_transport_plugin_handle_method_call(plugin, method_call);
}

void orbits_transport_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  OrbitsTransportPlugin* plugin = ORBITS_TRANSPORT_PLUGIN(
      g_object_new(orbits_transport_plugin_get_type(), nullptr));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "app.orbits/transport",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_object_unref(plugin);
}
