// Cross-platform WebSocket opener for the signaling socket.
//
// On native (dart:io) we set a protocol-level `pingInterval` on the underlying
// WebSocket. dart:io then sends WS ping frames and closes the socket if a pong
// doesn't arrive within the interval — so a half-open TCP connection (e.g. a
// mobile NAT rebinding / network switch) is detected in ~pingInterval and
// drives a fast reconnect, instead of hanging for the multi-minute OS TCP
// timeout (audit M4). This needs no cooperation from the PeerJS server: WS
// ping/pong is handled at the protocol layer by any compliant ws server.
//
// On web the browser owns the socket and reports closure reliably (and exposes
// no pingInterval knob), so we use the plain channel.

import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_channel_io.dart' if (dart.library.html) 'ws_channel_web.dart';

/// Open a [WebSocketChannel] to [uri]. [pingInterval] is honoured on native
/// and ignored on web.
Future<WebSocketChannel> openSignalingChannel(
  Uri uri, {
  Duration? pingInterval,
}) =>
    openChannel(uri, pingInterval: pingInterval);
