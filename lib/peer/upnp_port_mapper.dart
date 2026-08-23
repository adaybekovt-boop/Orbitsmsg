// Best-effort UPnP/IGD port mapper (dart:io). Opens an inbound TCP port on the
// home router so internet guests can reach the host's embedded signaling
// server. STRICTLY best-effort and fully time-boxed: any failure (no IGD, UPnP
// disabled, weird router) resolves to null and the room stays LAN-only — this
// never throws into the room-creation path and never hangs it.
//
// Flow: SSDP M-SEARCH (UDP multicast) → fetch device description → find the
// WAN connection service → GetExternalIPAddress + AddPortMapping (SOAP). All
// parsing lives in upnp_parse.dart (pure, unit-tested); this file is just the
// dart:io network plumbing around it.
//
// NOTE: untested against real routers in this environment — verify on a live
// network. It is written to fail safe, not to be clever.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'upnp_parse.dart';

/// A successful mapping, with what to put in the invite and how to undo it.
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
  final String protocol; // 'TCP'

  /// `ip:port` for the invite's `pub=` field.
  String get publicHostPort => '$externalIp:$externalPort';
}

class UpnpPortMapper {
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;

  /// Try to map [internalPort] (TCP) from [internalHost] (this device's LAN ip)
  /// to the same external port. Returns the mapping or null on any failure.
  /// The whole attempt is bounded by [timeout].
  Future<UpnpMapping?> mapPort({
    required int internalPort,
    required String internalHost,
    int leaseSeconds = 3600,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      return await _mapPortImpl(
        internalPort: internalPort,
        internalHost: internalHost,
        leaseSeconds: leaseSeconds,
      ).timeout(timeout);
    } catch (_) {
      return null; // fail safe → LAN-only
    }
  }

  Future<UpnpMapping?> _mapPortImpl({
    required int internalPort,
    required String internalHost,
    required int leaseSeconds,
  }) async {
    final location = await _discoverIgdLocation();
    if (location == null) return null;

    final descUri = Uri.tryParse(location);
    if (descUri == null || !isAllowedUpnpUri(descUri)) return null;
    final descXml = await _httpGet(descUri);
    if (descXml == null) return null;

    final svc = parseWanService(descXml, descUri);
    if (svc == null) return null;
    final controlUri = Uri.tryParse(svc.controlUrl);
    if (controlUri == null || !isAllowedUpnpUri(controlUri)) return null;

    // External IP (informational for the invite; mapping can still succeed if
    // this fails, but we need an ip for `pub=`, so bail if absent).
    final ipResp = await _soap(controlUri, svc.serviceType,
        'GetExternalIPAddress', const {});
    final externalIp = ipResp == null ? null : parseExternalIp(ipResp);
    if (externalIp == null || externalIp.isEmpty) return null;

    final addResp = await _soap(controlUri, svc.serviceType, 'AddPortMapping', {
      'NewRemoteHost': '',
      'NewExternalPort': internalPort,
      'NewProtocol': 'TCP',
      'NewInternalPort': internalPort,
      'NewInternalClient': internalHost,
      'NewEnabled': 1,
      'NewPortMappingDescription': 'Orbits room',
      'NewLeaseDuration': leaseSeconds,
    });
    if (addResp == null) return null; // SOAP fault / refused

    return UpnpMapping(
      externalIp: externalIp,
      externalPort: internalPort,
      serviceType: svc.serviceType,
      controlUrl: svc.controlUrl,
      protocol: 'TCP',
    );
  }

  /// Best-effort removal of a mapping created by [mapPort].
  Future<void> unmap(UpnpMapping mapping) async {
    try {
      final controlUri = Uri.tryParse(mapping.controlUrl);
      if (controlUri == null || !isAllowedUpnpUri(controlUri)) return;
      await _soap(controlUri, mapping.serviceType, 'DeletePortMapping', {
        'NewRemoteHost': '',
        'NewExternalPort': mapping.externalPort,
        'NewProtocol': mapping.protocol,
      }).timeout(const Duration(seconds: 4));
    } catch (_) {/* best-effort */}
  }

  // ── SSDP discovery ──
  Future<String?> _discoverIgdLocation() async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.readEventsEnabled = true;
      const targets = [
        'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
        'urn:schemas-upnp-org:service:WANIPConnection:1',
        'ssdp:all',
      ];
      for (final st in targets) {
        final msg = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_ssdpAddress:$_ssdpPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $st\r\n\r\n';
        sock.send(utf8.encode(msg), InternetAddress(_ssdpAddress), _ssdpPort);
      }

      final completer = Completer<String?>();
      final sub = sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock?.receive();
        if (dg == null) return;
        final resp = utf8.decode(dg.data, allowMalformed: true);
        final loc = parseSsdpLocation(resp);
        if (loc == null) return;
        final locUri = Uri.tryParse(loc);
        if (locUri == null || !isAllowedUpnpUri(locUri)) return;
        if (!completer.isCompleted) completer.complete(loc);
      });
      // Bounded wait for the first usable LOCATION.
      final result = await completer.future
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      sock?.close();
    }
  }

  static const _maxHttpBytes = 256 * 1024;

  Future<String?> _httpGet(Uri uri) async {
    if (!isAllowedUpnpUri(uri)) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      req.maxRedirects = 0;
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return null;
      return await _readLimited(resp, _maxHttpBytes);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _soap(
    Uri controlUri,
    String serviceType,
    String action,
    Map<String, Object?> args,
  ) async {
    if (!isAllowedUpnpUri(controlUri)) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final body = buildSoapBody(serviceType, action, args);
      final req = await client.postUrl(controlUri);
      req.followRedirects = false;
      req.maxRedirects = 0;
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"')
        ..set('SOAPAction', soapActionHeader(serviceType, action));
      req.add(utf8.encode(body));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return null; // SOAP fault
      return await _readLimited(resp, _maxHttpBytes);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

Future<String?> _readLimited(HttpClientResponse resp, int maxBytes) async {
  final buf = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    buf.add(chunk);
    if (buf.length > maxBytes) return null;
  }
  return utf8.decode(buf.takeBytes(), allowMalformed: true);
}
