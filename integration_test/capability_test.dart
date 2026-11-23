import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rtpath/capabilities.dart';
import 'package:rtpath/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('probes real Android capabilities as the app UID', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: app.CapabilityPage()));
    final report = await inspectCapabilities();
    await tester.pumpAndSettle();
    expect(find.text('RtPath 能力检测'), findsOneWidget);

    expect(report.androidApi, greaterThanOrEqualTo(29));
    expect(report.nativeAbi, isIn(['arm64-v8a', 'x86_64']));
    expect(report.applicationUid, greaterThanOrEqualTo(10000));
    expect(report.fileError, isNull);
    expect(report.inotifyError, isNull);
    expect(report.sqliteVersion, isNotEmpty);
    expect(report.trigramError, isNull);

    expect(report.directories, hasLength(3));
    expect(report.directories.first.error, isNull);
    final scope = report.directories.last;
    expect(scope.path, isNotEmpty);

    // Visibility of shared storage depends on Android version and permissions.
    // Report it without treating a denied directory as a broken app probe.
    // ignore: avoid_print
    print(
      'Android ${report.androidRelease} (API ${report.androidApi}), '
      '${report.nativeAbi}, Linux ${report.kernelRelease}, '
      'UID ${report.applicationUid}, SQLite ${report.sqliteVersion}, '
      'all-files access: ${report.allFilesAccess}, '
      'shared root: ${scope.error ?? 'readable'}, '
      'app external: ${report.directories[1].error ?? 'readable'}',
    );
    debugPrint('RtPath phase 3: ordinary namespace ${report.mountNamespace}');
    for (final directory in report.directories) {
      debugPrint(
        'RtPath phase 3: ordinary ${directory.path} · ${directory.mount ?? directory.error}',
      );
    }
  });
}
