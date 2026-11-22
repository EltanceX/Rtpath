import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtpath/main.dart';

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

    await tester.pumpWidget(const RtPathApp());
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
}
