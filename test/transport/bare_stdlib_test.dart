import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbits_flutter/transport/bare_stdlib.dart';

void main() {
  test('bare stdlib pack excludes swarm/DHT and unzip skips forbidden names', () {
    expect(kBareStdlibRootPackages, contains('bare-fs'));
    expect(kBareStdlibRootPackages, isNot(contains('hyperswarm')));
    expect(bareStdlibNameForbidden('node_modules/hyperswarm/index.js'), isTrue);
    expect(bareStdlibNameForbidden('node_modules/hyperdht/index.js'), isTrue);
    expect(bareStdlibNameForbidden('https://example.invalid/bare-fs'), isTrue);
    expect(bareStdlibNameForbidden('node_modules/bare-fs/package.json'), isFalse);
    expect(
      bundledStdlibZipCandidates(),
      contains('tool${Platform.pathSeparator}connectivity_harness'
          '${Platform.pathSeparator}$kBareStdlibZipName'),
    );
    final pack =
        File('tool/connectivity_harness/pack-bare-stdlib.sh').readAsStringSync();
    expect(pack, contains('NEVER downloads'));
    expect(pack, isNot(contains('curl')));
    expect(pack, contains('refusing zip that contains hyperswarm/hyperdht'));
    expect(
      File('tool/ci/vendor_bare_stdlib.sh').readAsStringSync(),
      contains('pack-bare-stdlib.sh'),
    );
    expect(kBareStdlibZipName, 'bare_stdlib.zip');
  });

  test('extractBareStdlibZip writes bare-fs and drops hyperswarm entries', () {
    final dir = Directory.systemTemp.createTempSync('orbits-stdlib-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final zip = File('${dir.path}/in.zip');
    final archive = Archive();
    void add(String name, String body) {
      final bytes = body.codeUnits;
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('node_modules/bare-fs/package.json', '{"name":"bare-fs"}');
    add('node_modules/hyperswarm/index.js', 'no');
    add('../evil.js', 'no');
    zip.writeAsBytesSync(ZipEncoder().encode(archive));
    extractBareStdlibZip(zip, dir);
    expect(
      File('${dir.path}/node_modules/bare-fs/package.json').existsSync(),
      isTrue,
    );
    expect(
      File('${dir.path}/node_modules/hyperswarm/index.js').existsSync(),
      isFalse,
    );
    expect(File('${dir.path}/evil.js').existsSync(), isFalse);
  });
}
