// Pure parsing helpers for the best-effort UPnP/IGD port mapper
// (upnp_port_mapper.dart). Kept free of dart:io so the fiddly string-munging —
// the part most likely to have bugs — is unit-testable without a router.
//
// UPnP IGD port mapping is inherently best-effort: routers vary wildly and
// many disable it. These helpers parse the well-known SSDP + SOAP shapes with
// tolerant regexes (not a full XML parser, to avoid a new dependency); on any
// shape we don't recognise the caller falls back to LAN-only.

/// True if [uri] is a safe UPnP HTTP(S) target: no credentials, IPv4
/// RFC1918 only. Blocks SSRF via a hostile SSDP LOCATION or controlURL
/// (localhost, link-local metadata, public internet).
bool isAllowedUpnpUri(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.host.isEmpty) return false;
  return _isRfc1918Ipv4(uri.host);
}

bool _isRfc1918Ipv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final oct = <int>[];
  for (final p in parts) {
    if (p.isEmpty || (p.length > 1 && p.startsWith('0'))) return false;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return false;
    oct.add(n);
  }
  final a = oct[0];
  final b = oct[1];
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}

/// Extract the `LOCATION` header (the device-description URL) from an SSDP
/// M-SEARCH response. Case-insensitive header name, trims CR/LF.
String? parseSsdpLocation(String response) {
  for (final rawLine in response.split('\n')) {
    final line = rawLine.trim();
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final name = line.substring(0, idx).trim().toLowerCase();
    if (name == 'location') {
      final value = line.substring(idx + 1).trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

/// A WAN connection service found in an IGD device description.
class UpnpService {
  const UpnpService({required this.serviceType, required this.controlUrl});

  /// e.g. `urn:schemas-upnp-org:service:WANIPConnection:1`
  final String serviceType;

  /// Absolute control URL (already resolved against the description base).
  final String controlUrl;
}

/// Find the WAN IP/PPP connection service in a device-description XML and
/// resolve its controlURL against [baseUrl]. Returns null if no usable service
/// is present. Prefers WANIPConnection over WANPPPConnection.
UpnpService? parseWanService(String descriptionXml, Uri baseUrl) {
  // Pull every <service>…</service> block, then pick the WAN connection one.
  final serviceBlocks = RegExp(
    r'<service>(.*?)</service>',
    dotAll: true,
    caseSensitive: false,
  ).allMatches(descriptionXml);

  UpnpService? ppp;
  for (final m in serviceBlocks) {
    final block = m.group(1) ?? '';
    final type = _tagText(block, 'serviceType');
    final control = _tagText(block, 'controlURL');
    if (type == null || control == null) continue;
    final lower = type.toLowerCase();
    final isIp = lower.contains('wanipconnection');
    final isPpp = lower.contains('wanpppconnection');
    if (!isIp && !isPpp) continue;
    final resolved = _resolveUrl(baseUrl, control.trim());
    final resolvedUri = Uri.tryParse(resolved);
    if (resolvedUri == null || !isAllowedUpnpUri(resolvedUri)) continue;
    final svc = UpnpService(serviceType: type.trim(), controlUrl: resolved);
    if (isIp) return svc; // strongest preference
    ppp ??= svc;
  }
  return ppp;
}

/// Build a SOAP envelope for an IGD control action.
String buildSoapBody(
  String serviceType,
  String action,
  Map<String, Object?> args,
) {
  final sb = StringBuffer()
    ..write('<?xml version="1.0"?>')
    ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ')
    ..write('s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
    ..write('<s:Body>')
    ..write('<u:$action xmlns:u="$serviceType">');
  args.forEach((k, v) {
    sb.write('<$k>${_xmlEscape('${v ?? ''}')}</$k>');
  });
  sb
    ..write('</u:$action>')
    ..write('</s:Body>')
    ..write('</s:Envelope>');
  return sb.toString();
}

/// The SOAPAction header value for an action on a service.
String soapActionHeader(String serviceType, String action) =>
    '"$serviceType#$action"';

/// Extract `NewExternalIPAddress` from a GetExternalIPAddress SOAP response.
String? parseExternalIp(String soapResponse) {
  final ip = _tagText(soapResponse, 'NewExternalIPAddress');
  if (ip == null) return null;
  final t = ip.trim();
  return t.isEmpty ? null : t;
}

// ── internals ──

String? _tagText(String xml, String tag) {
  // Matches <tag>…</tag> and <ns:tag>…</ns:tag>, ignoring attributes.
  final re = RegExp(
    '<(?:[\\w-]+:)?$tag\\b[^>]*>(.*?)</(?:[\\w-]+:)?$tag>',
    dotAll: true,
    caseSensitive: false,
  );
  final m = re.firstMatch(xml);
  return m?.group(1);
}

String _resolveUrl(Uri base, String ref) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  try {
    return base.resolve(ref).toString();
  } catch (_) {
    final origin = '${base.scheme}://${base.host}:${base.port}';
    return ref.startsWith('/') ? '$origin$ref' : '$origin/$ref';
  }
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
