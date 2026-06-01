// Web stub for upnp_port_mapper.dart. A browser can't open UDP sockets or map
// router ports, and a web build never hosts the server anyway. Exists only so
// the conditional import in room_signaling_host.dart resolves on web. API
// surface mirrors the dart:io implementation.

class UpnpMapping {
  UpnpMapping({
    required this.externalIp,
    required this.externalPort,
    required this.serviceType,
    required this.controlUrl,
    required this.protocol,
  });

  final String externalIp;
  final int externalPort;
  final String serviceType;
  final String controlUrl;
  final String protocol;

  String get publicHostPort => '$externalIp:$externalPort';
}

class UpnpPortMapper {
  Future<UpnpMapping?> mapPort({
    required int internalPort,
    required String internalHost,
    int leaseSeconds = 3600,
    Duration timeout = const Duration(seconds: 6),
  }) async =>
      null;

  Future<void> unmap(UpnpMapping mapping) async {}
}
