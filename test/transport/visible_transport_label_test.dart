import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/native_transport_host.dart';

void main() {
  test('dev flag alone does not claim Bare/Hyperswarm is active', () {
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: true,
        attached: false,
        backend: 'none',
        lastError: '',
      ),
      'Bare/Hyperswarm (dev) not running',
    );
  });

  test('Bare is shown only after a confirmed hyperswarm attach', () {
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: true,
        attached: true,
        backend: 'hyperswarm',
        lastError: '',
      ),
      'Bare/Hyperswarm (dev)',
    );
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: false,
        attached: true,
        backend: 'hyperswarm',
        lastError: '',
      ),
      'Bare/Hyperswarm',
    );
  });

  test('default production path is PeerJS', () {
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: false,
        attached: false,
        backend: 'none',
        lastError: '',
      ),
      'PeerJS',
    );
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: false,
        attached: false,
        backend: 'peerjs',
        lastError: '',
      ),
      'PeerJS',
    );
  });

  test('failed non-PeerJS backend is unavailable/error', () {
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: false,
        attached: false,
        backend: 'hyperswarm',
        lastError: 'spawn failed',
      ),
      'unavailable/error',
    );
    expect(
      orbitsVisibleTransportLabel(
        devBareRequested: true,
        attached: false,
        backend: 'none',
        lastError: 'spawn failed',
      ),
      'Bare/Hyperswarm (dev) failed',
    );
  });
}
