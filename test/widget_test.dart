import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtpath/main.dart';
import 'package:rtpath/platform/scan_api.g.dart';
import 'package:rtpath/search_results.dart';

void main() {
  const channel = MethodChannel('io.github.eltancex.rtpath/capabilities');

  testWidgets('shows native checks and limited ordinary access', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'inspect');
      return {
        'androidRelease': '16',
        'androidApi': 36,
        'kernelRelease': '5.15',
        'nativeAbi': 'arm64-v8a',
        'applicationUid': 10234,
        'fileError': null,
        'inotifyError': null,
        'sqlite': {'version': '3.50.2', 'trigramError': null},
        'allFilesAccess': false,
        'directories': [
          {'label': '应用内部目录', 'path': '/data/user/0/example', 'error': null},
          {
            'label': '共享存储根目录',
            'path': '/storage/emulated/0',
            'error': 'Permission denied',
          },
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const MaterialApp(home: CapabilityPage()));
    await tester.pumpAndSettle();

    expect(find.text('Android 16 · API 36'), findsOneWidget);
    expect(find.text('原生文件读取 · 通过'), findsOneWidget);
    expect(find.text('inotify 变更事件 · 通过'), findsOneWidget);
    expect(find.text('SQLite FTS5 trigram · 通过'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('共享存储根目录 · 不可用'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Permission denied'), findsOneWidget);
  });

  testWidgets('shows search metadata and copy action at both widths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const path = '/storage/emulated/0/Download/Main.kt';
    String? copied;
    final entry = SearchEntry(
      name: 'Main.kt',
      path: path,
      kind: EntryKind.file,
      bytes: 1024,
      modifiedMillis: DateTime(2024, 6, 10, 12).millisecondsSinceEpoch,
    );

    Future<void> layoutAt(double width) async {
      tester.view.physicalSize = Size(width, 720);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SearchResultHeader(
                  order: SearchOrder.size,
                  descending: true,
                  onSort: (_) {},
                ),
                SearchResultRow(entry: entry, onCopy: (path) => copied = path),
              ],
            ),
          ),
        ),
      );
    }

    await layoutAt(390);
    expect(find.text('修改时间'), findsNothing);
    expect(find.textContaining('1.0 KiB · 2024-06-10'), findsOneWidget);
    await tester.tap(find.byTooltip('复制路径'));
    expect(copied, path);

    await layoutAt(960);
    expect(find.text('修改时间'), findsOneWidget);
    expect(find.text('1.0 KiB'), findsOneWidget);
    expect(find.text(path), findsOneWidget);
  });
}
