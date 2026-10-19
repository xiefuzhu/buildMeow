import 'package:mapart_core/mapart_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late VersionTable versions;

  setUpAll(() {
    versions = loadVersionTable();
  });

  test('targets only the latest release', () {
    expect(versions.versions, hasLength(1));
    expect(versions.latest.id, '26.1.2');
    expect(versions.latest.dataVersion, 4790);
    expect(versions.latest.blockSetAlias, '1.20');
    expect(versions.latest.minY, -64);
    expect(versions.latest.maxY, 319);
    expect(versions.latest.height, 384);
  });

  test('the default target is that release', () {
    expect(versions.byId(VersionTable.defaultVersionId)?.id, '26.1.2');
  });

  test('the block set alias still resolves vendored blocks', () {
    final table = loadColorTable();
    final resolved = table[0].blocks
        .where((b) => b.stateFor(versions.latest.blockSetAlias) != null)
        .length;
    expect(resolved, greaterThan(0));
  });

  test('requiring an unknown release throws', () {
    expect(() => versions.require('1.99'), throwsArgumentError);
    expect(versions.byId('1.99'), isNull);
  });
}
