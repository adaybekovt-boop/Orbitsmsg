// Native: persist chat files next to the journal, not under /tmp.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String?> localAttachmentStoreDir() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final root = Directory(
      '${dir.path}${Platform.pathSeparator}orbits-file-blobs',
    );
    if (root.path.contains('://')) return null;
    root.createSync(recursive: true);
    return root.path;
  } catch (_) {
    return null;
  }
}
