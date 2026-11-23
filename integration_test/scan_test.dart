import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rtpath/main.dart' as app;
import 'package:rtpath/platform/scan_api.g.dart';

import 'capability_test.dart' as capabilities;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  capabilities.main();
  final api = ScanApi();

  testWidgets('scans, publishes, cancels and reopens the ordinary index', (
    tester,
  ) async {
    final locations = await api.locations();
    final internal = locations.singleWhere((it) => it.id == 'app-files');
    expect(
      internal.path,
      endsWith('/io.github.eltancex.rtpath.testhost/files'),
    );
    final marker = File('${internal.path}/.rtpath-test-restart.json');
    if (await marker.exists()) {
      final saved =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      final scope = saved['scope'] as String;
      final generation = saved['generation'] as String;
      final sharedScope = saved['sharedScope'] as String?;
      expect(await api.status(), isNull);
      final indexes = await api.indexes();
      expect(
        indexes.singleWhere((it) => it.scopeId == scope).generation,
        generation,
      );
      final page = await api.search(scope, 'replacement-新');
      expect(page?.generation, generation);
      expect(page?.entries.single.name, 'Replacement-新.txt');
      if (sharedScope != null) {
        expect(
          locations.singleWhere((it) => it.id == 'shared-primary').canScan,
          isFalse,
        );
        expect(indexes.any((it) => it.scopeId == sharedScope), isFalse);
        expect(await api.search(sharedScope, '项目%'), isNull);
        debugPrint('RtPath phase 1: revoked shared index hidden from queries');
      }
      await Directory(saved['fixture'] as String).delete(recursive: true);
      await marker.delete();
      debugPrint(
        'RtPath phase 1: persisted generation verified after process restart',
      );
      return;
    }

    const testShared = bool.fromEnvironment('RTPATH_TEST_SHARED');
    String? sharedScope;
    if (testShared) {
      final shared = locations.singleWhere((it) => it.id == 'shared-primary');
      expect(shared.canScan, isTrue);
      final download = await Directory('${shared.path}/Download').create();
      final fixture = await download.createTemp('rtpath-verify-');
      try {
        await File('${fixture.path}/Shared-项目%.txt').writeAsString('shared');
        final relative = fixture.path.substring(shared.path.length + 1);
        final started = await api.startScan(shared.id, relative);
        sharedScope = started.scopeId;
        final finished = await _waitFor(
          api,
          started.taskId,
          (it) => !_active(it),
        );
        expect(finished.state, ScanState.completed, reason: finished.message);
        expect(finished.entries, 1);
        final page = await api.search(started.scopeId, '项目%');
        expect(page?.entries.single.path, '${fixture.path}/Shared-项目%.txt');
      } finally {
        await fixture.delete(recursive: true);
      }
      debugPrint('RtPath phase 1: authorized shared storage verified');
    }

    final fixture = await Directory(internal.path).createTemp('rtpath-verify-');
    var saveForRestart = false;
    try {
      final relative = fixture.path.substring(internal.path.length + 1);
      final child = await Directory('${fixture.path}/nested').create();
      final seed = await File('${child.path}/Seed-项目_%.txt')
          .writeAsString('seed');
      await Link('${fixture.path}/loop').create(fixture.path);
      final first = await api.startScan(internal.id, relative);
      final baseline = await _waitFor(api, first.taskId, (it) => !_active(it));
      expect(baseline.state, ScanState.completed, reason: baseline.message);
      expect(baseline.published, isTrue);
      expect(baseline.entries, 3);
      final hit = (await api.search(
        first.scopeId,
        'SEED-项目_%',
      ))?.entries.single;
      expect(hit?.path, seed.path);
      expect(hit?.bytes, 4);
      expect(
        (await api.search(first.scopeId, 'loop'))?.entries.single.kind,
        EntryKind.symlink,
      );
      expect((await api.search(first.scopeId, '*'))?.entries, isEmpty);

      await File('${fixture.path}/Replacement-新.txt').writeAsString('new');
      await seed.delete();
      final bulk = await Directory('${fixture.path}/bulk').create();
      for (var i = 0; i < 24000; i++) {
        File('${bulk.path}/entry-$i').createSync();
      }

      final rescan = await api.startScan(internal.id, relative);
      await _waitFor(
        api,
        rescan.taskId,
        (it) => it.entries > 0 || !_active(it),
      );
      final during = await api.search(first.scopeId, 'seed');
      expect(during?.generation, first.taskId);
      expect(during?.entries.single.path, seed.path);
      expect(await api.cancelScan(rescan.taskId), isTrue);
      final cancelled = await _waitFor(
        api,
        rescan.taskId,
        (it) => !_active(it),
      );
      expect(cancelled.state, ScanState.cancelled);
      expect(cancelled.published, isFalse);
      expect(
        (await api.search(first.scopeId, 'seed'))?.entries.single.path,
        seed.path,
      );
      expect(
        (await api.search(first.scopeId, 'replacement'))?.entries,
        isEmpty,
      );

      await bulk.delete(recursive: true);
      final deep = await Directory('${fixture.path}/deep').create();
      var leaf = deep;
      for (var i = 0; i < 513; i++) {
        leaf = Directory('${leaf.path}/d')..createSync();
      }
      final partial = await api.startScan(internal.id, relative);
      final incomplete = await _waitFor(
        api,
        partial.taskId,
        (it) => !_active(it),
      );
      expect(incomplete.state, ScanState.partial);
      expect(incomplete.published, isFalse);
      expect(
        (await api.search(first.scopeId, 'seed'))?.generation,
        first.taskId,
      );

      final newPartial = await api.startScan(internal.id, '$relative/deep');
      final firstPartial = await _waitFor(
        api,
        newPartial.taskId,
        (it) => !_active(it),
      );
      expect(firstPartial.state, ScanState.partial);
      expect(firstPartial.published, isTrue);
      expect(
        (await api.indexes())
            .singleWhere((it) => it.scopeId == newPartial.scopeId)
            .partial,
        isTrue,
      );
      await deep.delete(recursive: true);

      final replacement = await api.startScan(internal.id, relative);
      final completed = await _waitFor(
        api,
        replacement.taskId,
        (it) => !_active(it),
      );
      expect(completed.state, ScanState.completed, reason: completed.message);
      expect(completed.published, isTrue);
      final oldName = await api.search(first.scopeId, 'seed');
      expect(oldName?.generation, replacement.taskId);
      expect(oldName?.entries, isEmpty);

      final missing = await api.startScan(internal.id, '$relative/missing');
      final failed = await _waitFor(api, missing.taskId, (it) => !_active(it));
      expect(failed.state, ScanState.failed);
      expect(failed.published, isFalse);
      expect(await api.search(missing.scopeId, ''), isNull);

      app.main();
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, '搜索文件名');
      await tester.enterText(search, 'replacement-新');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Replacement-新.txt'), findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.byTooltip('打开扫描设置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '相对目录（可选）'),
        relative,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final startButton = find.text('开始扫描');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pumpAndSettle();
      expect(find.textContaining('扫描完成'), findsOneWidget);
      expect(find.text('Replacement-新.txt'), findsOneWidget);
      final uiScan = await api.status();
      expect(uiScan?.published, isTrue);
      expect(uiScan?.scopeId, first.scopeId);
      expect(uiScan?.taskId, isNot(replacement.taskId));

      await marker.writeAsString(
        jsonEncode({
          'fixture': fixture.path,
          'scope': first.scopeId,
          'generation': uiScan!.taskId,
          'sharedScope': sharedScope,
        }),
        flush: true,
      );
      saveForRestart = true;
      debugPrint(
        'RtPath phase 1: baseline, concurrent query, cancellation, republish and UI verified',
      );
    } finally {
      if (!saveForRestart) await fixture.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

bool _active(ScanStatus status) =>
    status.state == ScanState.running || status.state == ScanState.cancelling;

Future<ScanStatus> _waitFor(
  ScanApi api,
  String id,
  bool Function(ScanStatus) ready,
) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 25)) {
    final status = await api.status();
    if (status != null && status.taskId == id && ready(status)) return status;
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  fail('Timed out waiting for scan $id');
}
