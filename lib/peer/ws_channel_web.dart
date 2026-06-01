// Web WebSocket opener — the browser manages keepalive and reports closure
// reliably, and exposes no pingInterval knob, so [pingInterval] is ignored.
// See ws_channel.dart.

import 'package:web_socket_channel/web_socket_channel.dart';

Future<WebSocketChannel> openChannel(Uri uri, {Duration? pingInterval}) async {
  return WebSocketChannel.connect(uri);
}
