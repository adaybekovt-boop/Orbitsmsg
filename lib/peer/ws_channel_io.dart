// Native (dart:io) WebSocket opener — sets a protocol-level ping interval so
// dead/half-open sockets are detected quickly (audit M4). See ws_channel.dart.

import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<WebSocketChannel> openChannel(Uri uri, {Duration? pingInterval}) async {
  // Ownership passes to the returned IOWebSocketChannel, which closes it.
  // ignore: close_sinks
  final ws = await WebSocket.connect(uri.toString());
  if (pingInterval != null) {
    // dart:io sends WS ping frames on this cadence and closes the socket if no
    // pong returns within the interval — fast half-open detection.
    ws.pingInterval = pingInterval;
  }
  return IOWebSocketChannel(ws);
}
