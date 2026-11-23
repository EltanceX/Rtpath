import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtpath/main.dart';
import 'package:rtpath/platform/scan_api.g.dart';
import 'package:rtpath/search_page.dart';
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

  testWidgets('rebases stale pagination after scrolling stops', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const scope = 'scope';
    const generation = 'generation';
    var revision = 0;
    const pageSize = 24;
    final requests = <(int, int?)>[];

    WatchStatus watch() => WatchStatus(
      scopeId: scope,
      generation: generation,
      revision: revision,
      state: WatchState.live,
      watched: 1,
      failures: 0,
      sequence: revision,
    );

    void mock(String method, Future<Object?> Function(Object?) reply) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.rtpath.ScanApi.$method',
        ScanApi.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, reply);
      addTearDown(
        () => messenger.setMockDecodedMessageHandler<Object?>(channel, null),
      );
    }

    mock('locations', (_) async => [<ScanLocation>[]]);
    mock('status', (_) async => [null]);
    mock('watchStatus', (_) async => [watch()]);
    mock(
      'indexes',
      (_) async => [
        [
          PublishedIndex(
            scopeId: scope,
            generation: generation,
            path: '/fixture',
            entries: pageSize * 4,
            partial: false,
          ),
        ],
      ],
    );
    mock('search', (message) async {
      final cursor = (message! as List<Object?>).last as SearchCursor?;
      requests.add((revision, cursor?.revision));
      final reset = cursor != null && cursor.revision != revision;
      final start = cursor?.id ?? 0;
      final end = start + pageSize;
      return [
        SearchPage(
          generation: generation,
          revision: revision,
          reset: reset,
          entries: reset
              ? []
              : [
                  for (var i = start; i < end; ++i)
                    SearchEntry(
                      name: 'File $i',
                      path: '/fixture/$i',
                      kind: EntryKind.file,
                      bytes: revision + 1,
                      modifiedMillis: 0,
                    ),
                ],
          next: reset || end == pageSize * 4
              ? null
              : SearchCursor(
                  generation: generation,
                  revision: revision,
                  queryKey: '',
                  id: end,
                  scanCandidates: false,
                ),
        ),
      ];
    });

    await tester.pumpWidget(
      const MaterialApp(home: SearchScreen(diagnostics: SizedBox())),
    );
    await tester.pumpAndSettle();
    final view = find.byType(CustomScrollView);
    final position = tester.widget<CustomScrollView>(view).controller!.position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests, [(0, null), (0, 0)]);

    revision = 1;
    final drag = await tester.startGesture(tester.getCenter(view));
    await drag.moveBy(
      Offset(0, position.pixels - position.maxScrollExtent + 160),
    );
    await tester.pumpAndSettle();
    expect(position.isScrollingNotifier.value, isTrue);
    expect(position.pixels, greaterThan(0));
    expect(requests.last, (1, 0));
    final offset = position.pixels;
    final row = tester.widget<SearchResultRow>(
      find.byType(SearchResultRow).first,
    );
    final current = find.byWidgetPredicate(
      (widget) =>
          widget is SearchResultRow && widget.entry.path == row.entry.path,
    );
    expect(row.entry.bytes, 1);

    for (final latest in [2, 3]) {
      revision = latest;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'dev.flutter.pigeon.rtpath.IndexUpdates.changed',
        IndexUpdates.pigeonChannelCodec.encodeMessage([watch()]),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(requests.length, 3);
    expect(tester.widget<SearchResultRow>(current), same(row));
    expect(position.pixels, offset);

    await drag.cancel();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 170));
    await tester.pumpAndSettle();
    expect(requests, [(0, null), (0, 0), (1, 0), (3, null), (3, 3), (3, 3)]);
    expect(position.pixels, offset);
    expect(tester.widget<SearchResultRow>(current).entry.bytes, 4);
  });
}
