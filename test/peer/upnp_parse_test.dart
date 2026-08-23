// Pure-helper tests for the best-effort UPnP/IGD parser. No network — just the
// string/XML munging that's most likely to have bugs.

import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/peer/upnp_parse.dart';

void main() {
  group('parseSsdpLocation', () {
    test('extracts LOCATION header (case-insensitive)', () {
      const resp =
          'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=120\r\n'
          'Location: http://192.168.1.1:5000/rootDesc.xml\r\n'
          'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n';
      expect(parseSsdpLocation(resp), 'http://192.168.1.1:5000/rootDesc.xml');
    });

    test('returns null when no LOCATION present', () {
      expect(parseSsdpLocation('HTTP/1.1 200 OK\r\nST: x\r\n\r\n'), isNull);
    });
  });

  group('parseWanService', () {
    final base = Uri.parse('http://192.168.1.1:5000/rootDesc.xml');

    test('finds WANIPConnection and resolves a relative controlURL', () {
      const xml = '''
        <root><device><serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
            <controlURL>/ctl/IPConn</controlURL>
          </service>
        </serviceList></device></root>''';
      final svc = parseWanService(xml, base);
      expect(svc, isNotNull);
      expect(svc!.serviceType, contains('WANIPConnection'));
      expect(svc.controlUrl, 'http://192.168.1.1:5000/ctl/IPConn');
    });

    test('prefers WANIPConnection over WANPPPConnection', () {
      const xml = '''
        <root>
          <service>
            <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
            <controlURL>/ppp</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
            <controlURL>/ip</controlURL>
          </service>
        </root>''';
      final svc = parseWanService(xml, base);
      expect(svc!.serviceType, contains('WANIPConnection'));
      expect(svc.controlUrl, endsWith('/ip'));
    });

    test('falls back to WANPPPConnection when no IP service', () {
      const xml = '''
        <root><service>
          <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
          <controlURL>http://192.168.1.1:5000/ppp</controlURL>
        </service></root>''';
      final svc = parseWanService(xml, base);
      expect(svc!.serviceType, contains('WANPPPConnection'));
      expect(svc.controlUrl, 'http://192.168.1.1:5000/ppp');
    });

    test('returns null when no WAN connection service', () {
      const xml =
          '<root><service>'
          '<serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>'
          '<controlURL>/x</controlURL></service></root>';
      expect(parseWanService(xml, base), isNull);
    });
  });

  group('buildSoapBody / soapActionHeader', () {
    test('wraps the action with the service type and escapes args', () {
      const st = 'urn:schemas-upnp-org:service:WANIPConnection:1';
      final body = buildSoapBody(st, 'AddPortMapping', {
        'NewExternalPort': 53217,
        'NewPortMappingDescription': 'A & B <ok>',
      });
      expect(body, contains('<u:AddPortMapping xmlns:u="$st">'));
      expect(body, contains('<NewExternalPort>53217</NewExternalPort>'));
      expect(body, contains('A &amp; B &lt;ok&gt;'));
      expect(body, contains('</s:Envelope>'));
    });

    test('SOAPAction header format', () {
      const st = 'urn:schemas-upnp-org:service:WANIPConnection:1';
      expect(soapActionHeader(st, 'AddPortMapping'), '"$st#AddPortMapping"');
    });
  });

  group('parseExternalIp', () {
    test('extracts NewExternalIPAddress through a namespace prefix', () {
      const resp =
          '<?xml version="1.0"?>'
          '<s:Envelope><s:Body>'
          '<u:GetExternalIPAddressResponse>'
          '<NewExternalIPAddress>203.0.113.7</NewExternalIPAddress>'
          '</u:GetExternalIPAddressResponse>'
          '</s:Body></s:Envelope>';
      expect(parseExternalIp(resp), '203.0.113.7');
    });

    test('returns null when absent', () {
      expect(parseExternalIp('<x/>'), isNull);
    });
  });

  group('isAllowedUpnpUri (SSRF)', () {
    test('allows RFC1918 http(s) IPv4', () {
      expect(
        isAllowedUpnpUri(Uri.parse('http://192.168.1.1:5000/rootDesc.xml')),
        isTrue,
      );
      expect(isAllowedUpnpUri(Uri.parse('https://10.0.0.1/desc')), isTrue);
      expect(isAllowedUpnpUri(Uri.parse('http://172.16.0.1/ctl')), isTrue);
      expect(isAllowedUpnpUri(Uri.parse('http://172.31.255.255/ctl')), isTrue);
    });

    test(
      'rejects loopback, link-local, public, hostnames, and credentials',
      () {
        expect(isAllowedUpnpUri(Uri.parse('http://127.0.0.1/')), isFalse);
        expect(
          isAllowedUpnpUri(Uri.parse('http://169.254.169.254/latest')),
          isFalse,
        );
        expect(isAllowedUpnpUri(Uri.parse('http://8.8.8.8/')), isFalse);
        expect(isAllowedUpnpUri(Uri.parse('http://172.15.0.1/')), isFalse);
        expect(isAllowedUpnpUri(Uri.parse('http://172.32.0.1/')), isFalse);
        expect(isAllowedUpnpUri(Uri.parse('http://example.com/desc')), isFalse);
        expect(isAllowedUpnpUri(Uri.parse('file://192.168.1.1/x')), isFalse);
        expect(
          isAllowedUpnpUri(Uri.parse('http://user:pass@192.168.1.1/x')),
          isFalse,
        );
        expect(isAllowedUpnpUri(Uri.parse('http://192.168.1.01/x')), isFalse);
      },
    );
  });

  group('parseWanService SSRF', () {
    test('skips a controlURL pointing at link-local metadata', () {
      final base = Uri.parse('http://192.168.1.1:5000/rootDesc.xml');
      const xml = '''
        <root><service>
          <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
          <controlURL>http://169.254.169.254/latest/meta-data</controlURL>
        </service></root>''';
      expect(parseWanService(xml, base), isNull);
    });
  });
}
