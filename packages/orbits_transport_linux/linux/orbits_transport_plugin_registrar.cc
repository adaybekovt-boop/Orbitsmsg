#include "include/orbits_transport_linux/orbits_transport_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#include "orbits_transport_host.h"

#define ORBITS_TRANSPORT_PLUGIN(obj)                                         \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), orbits_transport_plugin_get_type(), \
                              OrbitsTransportPlugin))

struct _OrbitsTransportPlugin {
  GObject parent_instance;
  OrbitsBareHost host;
};

G_DEFINE_TYPE(OrbitsTransportPlugin, orbits_transport_plugin,
              g_object_get_type())

static const gchar* map_string(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return "";
  }
  return fl_value_get_string(value);
}

static int map_bool(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 0;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    return 0;
  }
  return fl_value_get_bool(value) ? 1 : 0;
}

static int64_t map_int(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 0;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return 0;
  }
  return fl_value_get_int(value);
}

static size_t map_uint8_len(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return 0;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr ||
      fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST) {
    return 0;
  }
  return fl_value_get_length(value);
}

static FlMethodResponse* reply_host(int code) {
  switch (code) {
    case kOrbitsHostOk:
      return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    case kOrbitsHostRemoteJs:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "REMOTE_JS", "production Bare must not fetch remote JS", nullptr));
    case kOrbitsHostNotStarted:
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("NOT_STARTED", "not started", nullptr));
    case kOrbitsHostSuspended:
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("SUSPENDED", "suspended", nullptr));
    case kOrbitsHostIpcFrame:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "IPC_FRAME", "IPC frame exceeds cap", nullptr));
    case kOrbitsHostPathRequired:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "PATH_REQUIRED", "sendFile requires a path", nullptr));
    case kOrbitsHostOversize:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "OVERSIZE", "attachment exceeds path-transfer cap", nullptr));
    case kOrbitsHostBundleMissing:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "BUNDLE_MISSING", "local Bare bundle missing", nullptr));
    case kOrbitsHostBundleTampered:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "BUNDLE_TAMPERED", "local bundle hash mismatch", nullptr));
    case kOrbitsHostAbiMismatch:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "ABI_MISMATCH", "unsupported IPC version", nullptr));
    case kOrbitsHostMalformed:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "MALFORMED", "malformed request", nullptr));
    case kOrbitsHostBareMissing:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "BARE_RUNTIME_MISSING", "linked Bare runtime is not shipped",
          nullptr));
    case kOrbitsHostRuntimeTampered:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "BUNDLE_TAMPERED", "local runtime hash mismatch", nullptr));
    case kOrbitsHostTimeout:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "TIMEOUT", "bare host startup timed out", nullptr));
    case kOrbitsHostCrashed:
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("CRASHED", "bare host crashed", nullptr));
    default:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "HOST_ERROR", "transport host rejected the request", nullptr));
  }
}

static void orbits_transport_plugin_handle_method_call(
    OrbitsTransportPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "start") == 0) {
    response = reply_host(orbits_bare_host_start(
        &self->host, map_bool(args, "remoteJs"), map_string(args, "remoteJsUrl"),
        map_string(args, "bundleUrl"), map_string(args, "scriptUrl"),
        map_string(args, "ipcVersion"), map_bool(args, "requireLocalBundle"),
        map_bool(args, "localBundlePresent"),
        map_string(args, "expectedBundleSha256"),
        map_string(args, "localBundleSha256")));
  } else if (strcmp(method, "stop") == 0) {
    response = reply_host(orbits_bare_host_stop(&self->host));
  } else if (strcmp(method, "publish") == 0) {
    response = reply_host(
        orbits_bare_host_publish(&self->host, map_string(args, "deviceId")));
  } else if (strcmp(method, "unpublish") == 0) {
    response = reply_host(orbits_bare_host_unpublish(&self->host));
  } else if (strcmp(method, "connect") == 0) {
    response = reply_host(orbits_bare_host_connect(&self->host));
  } else if (strcmp(method, "disconnect") == 0) {
    response = reply_host(orbits_bare_host_disconnect(&self->host));
  } else if (strcmp(method, "refreshNetwork") == 0) {
    response = reply_host(orbits_bare_host_refresh_network(&self->host));
  } else if (strcmp(method, "send") == 0) {
    response = reply_host(
        orbits_bare_host_send(&self->host, map_uint8_len(args, "frame")));
  } else if (strcmp(method, "sendFile") == 0) {
    response = reply_host(orbits_bare_host_send_file(
        &self->host, map_string(args, "path"), map_int(args, "sizeBytes")));
  } else if (strcmp(method, "suspend") == 0) {
    response = reply_host(orbits_bare_host_suspend(&self->host));
  } else if (strcmp(method, "resume") == 0) {
    response = reply_host(orbits_bare_host_resume(&self->host));
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

static void orbits_transport_plugin_init(OrbitsTransportPlugin* self) {
  self->host.started = 0;
  self->host.suspended = 0;
  self->host.published = 0;
}

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
