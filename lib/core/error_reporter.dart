// Port of src/core/errorReporter.js — centralised frontend error reporting.
//
// Captures:
//   - Errors thrown in Widget build/lifecycle (via FlutterError.onError).
//   - Uncaught async errors (via PlatformDispatcher.instance.onError).
//
// External sinks (Sentry, custom analytics) register via [registerSink] and
// receive a payload map identical to the JS shape. The console is always
// written to via `developer.log` so the payload shows up in the debug console.

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

typedef ErrorSink = void Function(Map<String, Object?> payload, Object? error);

final Set<ErrorSink> _sinks = <ErrorSink>{};
bool _installed = false;

/// Register an external error sink. Returns an unsubscribe function.
void Function() registerSink(ErrorSink fn) {
  _sinks.add(fn);
  return () => _sinks.remove(fn);
}

/// Emit an error to all registered sinks plus the console. Safe to call from
/// anywhere — sink failures are swallowed so reporting never crashes the app.
Map<String, Object?> reportError(Object? error, [Map<String, Object?>? extra]) {
  String message;
  String? stack;
  if (error is Error) {
    message = error.toString();
    stack = error.stackTrace?.toString();
  } else if (error is Exception) {
    message = error.toString();
  } else {
    message = (error ?? 'Unknown error').toString();
  }
  final payload = <String, Object?>{
    'message': message,
    'stack': stack,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'url': null,
    'userAgent': _userAgent(),
    if (extra != null) ...extra,
  };
  try {
    developer.log(
      '[orbits] ${payload['message']}',
      name: 'orbits',
      error: error,
      stackTrace: stack != null ? StackTrace.fromString(stack) : null,
    );
  } catch (_) {}
  for (final sink in _sinks.toList(growable: false)) {
    try {
      sink(payload, error);
    } catch (_) {}
  }
  return payload;
}

String _userAgent() {
  // Web-safe: avoid `dart:io` Platform (this file is reachable from main() on
  // web). `defaultTargetPlatform` + `kIsWeb` come from foundation and compile
  // everywhere; we trade the exact OS version for cross-platform safety.
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name;
}

/// Wire `FlutterError.onError` and `PlatformDispatcher.onError`. Idempotent —
/// safe to call multiple times (e.g. during hot-reload).
void installGlobalHandlers() {
  if (_installed) return;
  _installed = true;

  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    reportError(details.exception, {
      'source': 'FlutterError.onError',
      'library': details.library,
      'context': details.context?.toString(),
      'stack': details.stack?.toString(),
    });
    previousFlutter?.call(details);
  };

  final dispatcher = PlatformDispatcher.instance;
  final previousPlatform = dispatcher.onError;
  dispatcher.onError = (Object error, StackTrace stack) {
    reportError(error, {
      'source': 'PlatformDispatcher.onError',
      'stack': stack.toString(),
    });
    return previousPlatform?.call(error, stack) ?? true;
  };
}

/// Serialise a report into plain text for user-visible copy-to-clipboard.
/// Intentionally strips anything that could contain secrets (no full payload
/// dump — just message + stack + basic context).
String formatReportForClipboard(Map<String, Object?>? payload) {
  if (payload == null) return '';
  final ts = payload['timestamp'];
  final when = ts is int
      ? DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String()
      : DateTime.now().toIso8601String();
  final lines = <String>[
    'Orbits error @ $when',
    'URL: ${payload['url'] ?? 'n/a'}',
    'UA:  ${payload['userAgent'] ?? 'n/a'}',
    '',
    'Message: ${payload['message']}',
  ];
  final stack = payload['stack'];
  if (stack is String && stack.isNotEmpty) {
    lines.add('');
    lines.add('Stack:');
    final split = stack.split('\n');
    lines.add(split.take(20).join('\n'));
  }
  return lines.join('\n');
}
