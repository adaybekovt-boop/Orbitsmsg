import 'package:flutter/foundation.dart';

/// Checkbox on the create/join sheet and the in-chat banner.
const Key kRoomPlaintextAckKey = Key('room-plaintext-ack');

const String kRoomPlaintextAckLabelRu =
    'Я понимаю: организатор видит все сообщения и файлы.';

/// Host-plaintext rooms: no create/join/send without an explicit ack.
bool roomPlaintextActionAllowed({required bool acknowledgedHostCanRead}) =>
    acknowledgedHostCanRead;
