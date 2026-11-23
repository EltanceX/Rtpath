import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rtpath/main.dart' as app;
import 'package:rtpath/platform/scan_api.g.dart';

import 'capability_test.dart' as capabilities;

part 'recovery_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  capabilities.main();
  final api = ScanApi();
  var restarted = false;

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
    const run = String.fromEnvironment('RTPATH_TEST_RUN');
    Map<String, dynamic>? saved;
    if (await marker.exists()) {
      saved = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      if (saved['run'] != run) {
        final stale = Directory(saved['fixture'] as String);
        final allowed = RegExp(
          '^${RegExp.escape(internal.path)}/rtpath-verify-[A-Za-z0-9]+\$',
        );
        if (allowed.hasMatch(stale.path) && await stale.exists()) {
          await stale.delete(recursive: true);
        }
        await marker.delete();
        saved = null;
      }
    }
    if (saved != null) {
      restarted = true;
      final scope = saved['scope'] as String;
      final generation = saved['generation'] as String;
      final sharedScope = saved['sharedScope'] as String?;
      expect(await api.status(), isNull);
      expect(await api.watchStatus(scope), isNull);
      final indexes = await api.indexes();
      expect(
        indexes.singleWhere((it) => it.scopeId == scope).generation,
        generation,
      );
      final page = await api.find(scope, 'replacement-新');
      expect(page?.generation, generation);
      expect(page?.entries.single.name, 'Replacement-新.txt');
      if (sharedScope != null) {
        expect(
          locations.singleWhere((it) => it.id == 'shared-primary').canScan,
          isFalse,
        );
        expect(indexes.any((it) => it.scopeId == sharedScope), isFalse);
        expect(await api.find(sharedScope, '项目%'), isNull);
        debugPrint('RtPath phase 1: revoked shared index hidden from queries');
      }
      if (const bool.fromEnvironment('RTPATH_TEST_RECOVERY')) {
        final offline = await File('${saved['fixture']}/After-Restart.txt')
            .writeAsString('gap');
        expect((await api.find(scope, 'after-restart'))?.entries, isEmpty);
        final repair = await api.repair(scope);
        expect(
          (await _waitFor(api, repair.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        expect(
          (await api.find(scope, 'after-restart'))?.entries.single.path,
          offline.path,
        );
        debugPrint(
          'RtPath phase 5: process restart retained historical results and explicit repair rebuilt them',
        );
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
        final page = await api.find(started.scopeId, '项目%');
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
      final hit = (await api.find(first.scopeId, 'SEED-项目_%'))?.entries.single;
      expect(hit?.path, seed.path);
      expect(hit?.bytes, 4);
      expect(
        (await api.find(first.scopeId, 'loop'))?.entries.single.kind,
        EntryKind.symlink,
      );
      expect((await api.find(first.scopeId, '*'))?.entries, isEmpty);

      await File('${fixture.path}/Replacement-新.txt').writeAsString('new');
      await seed.delete();
      await _waitForPage(
        api,
        first.scopeId,
        'replacement',
        (it) => it.entries.length == 1,
      );
      await _waitForPage(
        api,
        first.scopeId,
        'seed',
        (it) => it.entries.isEmpty,
      );
      // Stage the large tree outside the watched scope so the cancellation
      // fixture does not inadvertently trigger overflow recovery first.
      final staging = await Directory(internal.path).createTemp('rtpath-bulk-');
      final Directory bulk;
      try {
        for (var i = 0; i < 24000; i++) {
          File('${staging.path}/entry-$i').createSync();
        }
        bulk = await staging.rename('${fixture.path}/bulk');
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }

      final rescan = await api.startScan(internal.id, relative);
      await _waitFor(
        api,
        rescan.taskId,
        (it) => it.entries > 0 || !_active(it),
      );
      final during = await api.find(first.scopeId, 'seed');
      expect(during?.generation, first.taskId);
      expect(during?.entries, isEmpty);
      expect(await api.cancelScan(rescan.taskId), isTrue);
      final cancelled = await _waitFor(
        api,
        rescan.taskId,
        (it) => !_active(it),
      );
      expect(cancelled.state, ScanState.cancelled);
      expect(cancelled.published, isFalse);
      expect((await api.find(first.scopeId, 'seed'))?.entries, isEmpty);
      expect(
        (await api.find(first.scopeId, 'replacement'))?.entries.single.name,
        'Replacement-新.txt',
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
      expect((await api.find(first.scopeId, 'seed'))?.generation, first.taskId);

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
      final oldName = await api.find(first.scopeId, 'seed');
      expect(oldName?.generation, replacement.taskId);
      expect(oldName?.entries, isEmpty);

      final missing = await api.startScan(internal.id, '$relative/missing');
      final failed = await _waitFor(api, missing.taskId, (it) => !_active(it));
      expect(failed.state, ScanState.failed);
      expect(failed.published, isFalse);
      expect(await api.find(missing.scopeId, ''), isNull);

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
          'run': run,
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

  testWidgets('searches, pages and scrolls without mixing index versions', (
    tester,
  ) async {
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    expect(
      location.path,
      endsWith('/io.github.eltancex.rtpath.testhost/files'),
    );
    final fixture = await Directory(location.path).createTemp('rtpath-search-');
    try {
      final relative = fixture.path.substring(location.path.length + 1);
      final primary = await Directory('${fixture.path}/src/Feature A')
          .create(recursive: true);
      final adjacent = await Directory('${fixture.path}/src-old/Feature A')
          .create(recursive: true);
      await File('${primary.path}/Main Activity.kt')
          .writeAsBytes(List.filled(1024, 1));
      await File('${primary.path}/Main-small.kt').writeAsString('small');
      await File('${adjacent.path}/Main Activity.kt')
          .writeAsBytes(List.filled(1100, 1));
      final quoted = await File('${primary.path}/Quote "100%".kt').create();
      final decomposed = await File('${primary.path}/cafe\u0301.txt').create();
      final rare = await File('${primary.path}/zz-稀有蓝.txt').create();

      final duplicatePaths = <String>[];
      final stamp = DateTime.utc(2024, 1, 2, 3, 4);
      for (var i = 0; i < 215; i++) {
        final dir = Directory('${fixture.path}/duplicates/$i')
          ..createSync(recursive: true);
        final file = File('${dir.path}/Same-Sort.dat')
          ..writeAsStringSync('same');
        file.setLastModifiedSync(stamp);
        duplicatePaths.add(file.path);
      }
      for (var i = 0; i < 2300; i++) {
        File('${fixture.path}/aa-padding-$i').createSync();
      }
      for (var i = 0; i < 165; i++) {
        File('${fixture.path}/page-${i.toString().padLeft(3, '0')}.txt')
            .createSync();
      }

      final started = await api.startScan(location.id, relative);
      final scope = started.scopeId;
      expect(
        (await _waitFor(api, started.taskId, (it) => !_active(it))).state,
        ScanState.completed,
      );

      expect(
        (await api.find(scope, 'name:CAFÉ.txt'))!.entries.single.path,
        decomposed.path,
      );
      expect(
        (await api.find(scope, '"\\"100%\\""'))!.entries.single.path,
        quoted.path,
      );
      expect(
        (await api.find(
          scope,
          'prefix:main ext:.KT path:"${primary.path}" size:>=1KiB size:<1.1KB',
        ))!.entries.single.bytes,
        1024,
      );
      expect(
        (await api.find(
          scope,
          'prefix:main ext:kt path:src size:>=1KiB',
        ))!.entries.single.path,
        '${primary.path}/Main Activity.kt',
      );
      expect(
        (await api.find(scope, 'prefix:main path:/elsewhere'))!.entries,
        isEmpty,
      );
      expect(
        (await api.find(
          scope,
          'ext:kt size:>=1kB',
          order: SearchOrder.size,
          descending: true,
        ))!.entries.map((it) => it.bytes),
        [1100, 1024],
      );

      for (final term in ['蓝', '稀有']) {
        final firstPage = (await api.find(scope, term))!;
        expect(firstPage.entries, isEmpty);
        expect(firstPage.next, isNotNull);
        final secondPage = (await api.find(
          scope,
          term,
          cursor: firstPage.next,
        ))!;
        expect(secondPage.entries.single.path, rare.path);
        expect(secondPage.next, isNull);
      }

      const exact = 'name:Same-Sort.dat';
      for (final order in SearchOrder.values) {
        final paths = await _allPaths(api, scope, exact, order, false);
        expect(paths, unorderedEquals(duplicatePaths));
        expect(await _allPaths(api, scope, exact, order, true), paths.reversed);
      }
      final oldCursor = (await api.find(scope, exact))!.next;
      expect(oldCursor, isNotNull);
      final replacement = await api.startScan(location.id, relative);
      expect(
        (await _waitFor(
          api,
          replacement.taskId,
          (it) => !_active(it),
        )).published,
        isTrue,
      );
      final stale = (await api.find(scope, exact, cursor: oldCursor))!;
      expect(stale.reset, isTrue);
      expect(stale.entries, isEmpty);

      await tester.pumpWidget(const SizedBox());
      app.main();
      await tester.pumpAndSettle();
      final search = find.widgetWithText(TextField, '搜索文件名');
      await tester.enterText(search, 'prefix:page-');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('page-000.txt'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('page-164.txt'),
        610,
        maxScrolls: 65,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('page-164.txt'), findsOneWidget);
      expect(search.hitTestable(), findsOneWidget);
      debugPrint('RtPath phase 2: query, cursor reset and scrolling verified');
    } finally {
      await fixture.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  const rootFixture = String.fromEnvironment('RTPATH_ROOT_FIXTURE');
  if (rootFixture.isNotEmpty) {
    testWidgets('explicit Root authorization, metadata pipe and disconnect', (
      tester,
    ) async {
      expect(rootFixture, startsWith('/data/local/tmp/rtpath-root-'));
      final scope = 'root:$rootFixture';
      expect((await api.rootAccess()).state, RootState.idle);
      expect((await api.indexes()).any((it) => it.scopeId == scope), isFalse);
      if (restarted) {
        final indexes = await api.rootIndexes();
        expect(indexes.any((it) => it.scopeId == scope), isTrue);
        expect(
          (await api.find(scope, 'Protected-项目'))?.entries.single.path,
          '$rootFixture/Protected-项目.txt',
        );
        debugPrint(
          'RtPath phase 3: persisted Root index available without reconnecting',
        );
        return;
      }

      await expectLater(
        Directory(rootFixture).list().toList(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        api.startRootScan(rootFixture),
        throwsA(isA<PlatformException>()),
      );
      await tester.pumpWidget(const SizedBox());
      app.main();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('扫描模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Root 模式'));
      await tester.pumpAndSettle();
      expect((await api.rootAccess()).state, RootState.idle);
      await tester.tap(find.text('连接 Root'));
      await tester.pump();
      final access = await _waitRoot(api);
      expect(access.state, RootState.connected, reason: access.message);
      expect(access.pid, greaterThan(0));
      expect(access.uid, 0);
      expect(access.namespace, startsWith('mnt:['));
      expect(access.mounts, hasLength(4));
      debugPrint(
        'RtPath phase 3: UID ${access.uid}, PID ${access.pid}, ${access.namespace}, ${access.selinux}',
      );
      for (final mount in access.mounts) {
        debugPrint('RtPath phase 3: $mount');
      }

      final probes = await api.probeRoot(rootFixture);
      expect(probes, hasLength(3));
      expect(probes.first, contains('mount '));
      for (final probe in probes) {
        debugPrint('RtPath phase 3: $probe');
      }
      await expectLater(
        api.startRootScan('$rootFixture/../'),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '绝对目录'),
        rootFixture,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final start = find.text('开始 Root 扫描');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      final first = await _waitForScope(api, scope);
      final published = await _waitFor(api, first.taskId, (it) => !_active(it));
      expect(published.state, ScanState.completed, reason: published.message);
      expect(published.entries, 24001);
      expect(published.published, isTrue);
      expect(
        (await api.find(scope, 'Protected-项目'))?.entries.single.path,
        '$rootFixture/Protected-项目.txt',
      );
      expect((await api.indexes()).any((it) => it.scopeId == scope), isFalse);
      final rootIndex = (await api.rootIndexes()).singleWhere(
        (it) => it.scopeId == scope,
      );
      expect(rootIndex.generation, first.taskId);
      expect(rootIndex.partial, isFalse);
      final watcher = await _waitWatch(api, scope, WatchState.live);
      final admitted = probes.first.contains('fanotify verified');
      expect(
        watcher.message,
        startsWith(admitted ? 'fanotify · ' : 'inotify · '),
      );
      debugPrint(
        'RtPath phase 6: ${probes.first}; selected ${watcher.message}',
      );

      final livePath = '$rootFixture/live-protected.txt';
      await _runRoot("printf 'first' > '$livePath'");
      final live = await _waitForPage(
        api,
        scope,
        'live-protected',
        (it) => it.entries.singleOrNull?.bytes == 5,
      );
      expect(live.generation, first.taskId);
      expect(live.revision, greaterThan(0));
      await _runRoot("mv '$livePath' '$rootFixture/live-renamed.txt'");
      await _waitForPage(
        api,
        scope,
        'live-renamed',
        (it) => it.entries.singleOrNull?.bytes == 5,
      );
      await _runRoot("rm '$rootFixture/live-renamed.txt'");
      await _waitForPage(api, scope, 'live-', (it) => it.entries.isEmpty);
      await _runRoot(
        "mkdir -p '$rootFixture/from/moved' '$rootFixture/to' && "
        "printf 'tree' > '$rootFixture/from/moved/fanotify-probe.txt'",
      );
      await _waitForPage(
        api,
        scope,
        'fanotify-probe',
        (it) =>
            it.entries.singleOrNull?.path ==
            '$rootFixture/from/moved/fanotify-probe.txt',
      );
      await _runRoot("mv '$rootFixture/from/moved' '$rootFixture/to/moved'");
      final moved = await _waitForPage(
        api,
        scope,
        'fanotify-probe',
        (it) =>
            it.entries.singleOrNull?.path ==
            '$rootFixture/to/moved/fanotify-probe.txt',
      );
      expect(moved.generation, first.taskId);
      await _runRoot(
        "rm '$rootFixture/to/moved/fanotify-probe.txt' && "
        "rmdir '$rootFixture/to/moved' '$rootFixture/from' '$rootFixture/to'",
      );
      await _waitForPage(
        api,
        scope,
        'fanotify-probe',
        (it) => it.entries.isEmpty,
      );
      debugPrint(
        'RtPath phase 4: protected Root scope updated through the metadata pipe',
      );

      final cancelled = await api.startRootScan(rootFixture);
      expect(await api.cancelScan(cancelled.taskId), isTrue);
      expect(
        (await _waitFor(api, cancelled.taskId, (it) => !_active(it))).state,
        ScanState.cancelled,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final disconnect = find.text('断开 Root');
      await tester.ensureVisible(disconnect);
      await tester.pumpAndSettle();
      final interrupted = await api.startRootScan(rootFixture);
      await _waitFor(
        api,
        interrupted.taskId,
        (it) => it.entries > 0 || !_active(it),
      );
      await tester.tap(disconnect);
      await tester.pump();
      final stopped = await _waitFor(
        api,
        interrupted.taskId,
        (it) => !_active(it),
      );
      expect(stopped.state, ScanState.failed);
      expect(stopped.published, isFalse);
      expect((await api.rootAccess()).state, RootState.idle);
      expect((await api.find(scope, 'Protected-项目'))?.generation, first.taskId);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('Root 未连接'), findsOneWidget);
      debugPrint(
        'RtPath phase 3: protected scope, cancellation, disconnect and index isolation verified',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    testWidgets('does not index its own SQLite writes through Root aliases', (
      tester,
    ) async {
      if (restarted) return;
      const package = 'io.github.eltancex.rtpath.testhost';
      const indexFiles = '/data/data/$package/no_backup';
      const alias = '/data/user/0/$package/no_backup';
      final fixture = await Directory(alias).createTemp('rtpath-feedback-');
      final name = fixture.path.split('/').last;
      final unrelated = await File('${fixture.path}/root-index.sqlite')
          .writeAsString('fixture');
      final live = File('$alias/$name-probe.txt');
      try {
        for (final path in [indexFiles, alias]) {
          await api.connectRoot();
          final access = await _waitRoot(api);
          expect(access.state, RootState.connected, reason: access.message);
          final scan = await api.startRootScan(path);
          final scope = scan.scopeId;
          final published = await _waitFor(
            api,
            scan.taskId,
            (it) => !_active(it),
          );
          expect(
            published.state,
            ScanState.completed,
            reason: published.message,
          );
          expect(published.published, isTrue);
          await _waitWatch(api, scope, WatchState.live);
          await _runRoot(
            "test -f '$path/root-index.sqlite' && test -f '$path/root-index.sqlite-wal' "
            "&& test -f '$path/root-index.sqlite-shm'",
          );
          final ordinary = await api.find(scope, 'ordinary-index.sqlite');
          expect(ordinary?.entries, isEmpty);
          final root = await api.find(scope, 'root-index.sqlite');
          expect(root?.entries.single.path, '$path/$name/root-index.sqlite');
          await unrelated.writeAsString('new bytes');
          await _waitForPage(
            api,
            scope,
            'root-index.sqlite',
            (it) => it.entries.singleOrNull?.bytes == 9,
          );
          final before = (await api.watchStatus(scope))!.revision;
          for (var size = 1; size <= 4; size++) {
            await live.writeAsString('x' * size);
            await _waitForPage(
              api,
              scope,
              '$name-probe.txt',
              (it) => it.entries.singleOrNull?.bytes == size,
            );
          }
          final revision = (await api.watchStatus(scope))!.revision;
          expect(revision, greaterThan(before));
          await Future<void>.delayed(const Duration(seconds: 2));
          final quiet = await api.watchStatus(scope);
          expect(quiet?.state, WatchState.live);
          expect(quiet?.revision, revision);
          expect(
            (await api.find(scope, 'root-index.sqlite'))?.entries.single.path,
            '$path/$name/root-index.sqlite',
          );
          debugPrint(
            'RtPath phase 4: SQLite feedback excluded via ${path.substring(0, path.indexOf(package))} '
            '(revision $before → $revision, unchanged for 2s)',
          );
          await api.disconnectRoot();
          await unrelated.writeAsString('fixture');
          await live.delete();
        }
      } finally {
        await api.disconnectRoot();
        if (await live.exists()) await live.delete();
        await fixture.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  testWidgets('reconciles a live tree and refreshes the visible query', (
    tester,
  ) async {
    if (restarted) return;
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    final fixture = await Directory(location.path).createTemp('rtpath-live-');
    final outside = await Directory(location.path).createTemp('rtpath-donor-');
    try {
      final left = await Directory('${fixture.path}/left').create();
      final right = await Directory('${fixture.path}/right').create();
      for (var i = 0; i < 140; ++i) {
        File('${left.path}/cursor-$i.txt').createSync();
      }
      final incoming = await Directory('${outside.path}/donor/nested')
          .create(recursive: true);
      await File('${incoming.path}/Moved-In-文件.txt').writeAsString('moved');
      final relative = fixture.path.substring(location.path.length + 1);
      final seed = await File('${left.path}/Live-Target.txt')
          .writeAsString('old');
      final scan = await api.startScan(location.id, relative);
      final scope = scan.scopeId;
      expect(
        (await _waitFor(api, scan.taskId, (it) => !_active(it))).published,
        isTrue,
      );
      expect((await api.watchStatus(scope))?.state, WatchState.live);
      expect((await api.watchStatus(scope))?.watched, 3);
      final before = (await api.find(scope, 'prefix:cursor-'))!;
      expect(before.next, isNotNull);

      await seed.writeAsString('different size');
      final changed = await _waitForPage(
        api,
        scope,
        'live-target',
        (it) => it.entries.singleOrNull?.bytes == 14,
      );
      expect(changed.generation, scan.taskId);
      expect(changed.revision, greaterThan(before.revision));
      expect(
        (await api.find(scope, 'prefix:cursor-', cursor: before.next))?.reset,
        isTrue,
      );

      final temp = await File('${left.path}/.editor-temp')
          .writeAsString('atomic save');
      await temp.rename(seed.path);
      await _waitForPage(
        api,
        scope,
        'live-target',
        (it) => it.entries.singleOrNull?.bytes == 11,
      );
      expect((await api.find(scope, 'editor-temp'))?.entries, isEmpty);

      final moved = '${right.path}/arrived';
      await Directory('${outside.path}/donor').rename(moved);
      await _waitForPage(
        api,
        scope,
        'moved-in',
        (it) =>
            it.entries.singleOrNull?.path == '$moved/nested/Moved-In-文件.txt',
      );
      final renamed = '${left.path}/renamed';
      await Directory(moved).rename(renamed);
      await _waitForPage(
        api,
        scope,
        'moved-in',
        (it) =>
            it.entries.singleOrNull?.path == '$renamed/nested/Moved-In-文件.txt',
      );
      expect(
        (await api.find(scope, 'moved-in path:right/arrived'))?.entries,
        isEmpty,
      );
      expect(
        (await api.find(
          scope,
          'moved-in path:left/renamed',
          order: SearchOrder.path,
        ))?.entries,
        hasLength(1),
      );
      final movedChild = await File('$renamed/nested/After-Rename.txt')
          .create();
      await _waitForPage(
        api,
        scope,
        'after-rename',
        (it) => it.entries.singleOrNull?.path == movedChild.path,
      );
      await Directory(renamed).rename('${outside.path}/exported');
      await _waitForPage(api, scope, 'moved-in', (it) => it.entries.isEmpty);
      expect((await api.find(scope, 'after-rename'))?.entries, isEmpty);
      expect((await api.watchStatus(scope))?.watched, 3);
      expect(
        (await api.indexes()).singleWhere((it) => it.scopeId == scope).entries,
        143,
      );

      await tester.pumpWidget(const SizedBox());
      app.main();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '搜索文件名'),
        'live-needle',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Live-Needle.txt'), findsNothing);
      final timer = Stopwatch()..start();
      final needle = await File('${fixture.path}/Live-Needle.txt')
          .writeAsString('live');
      final appeared = await _waitForPage(
        api,
        scope,
        'live-needle',
        (it) => it.entries.singleOrNull?.path == needle.path,
      );
      final backendMillis = timer.elapsedMilliseconds;
      await _waitForWidget(tester, find.text('Live-Needle.txt'), present: true);
      final visibleMillis = timer.elapsedMilliseconds;
      await needle.delete();
      await _waitForWidget(
        tester,
        find.text('Live-Needle.txt'),
        present: false,
      );
      expect(appeared.generation, scan.taskId);
      debugPrint(
        'RtPath phase 4: ordinary live query, cursor reset, move and atomic save verified '
        '(create: database ${backendMillis}ms, Flutter ${visibleMillis}ms)',
      );
    } finally {
      await fixture.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('replays events during baseline enumeration', (tester) async {
    if (restarted) return;
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    final fixture = await Directory(location.path).createTemp('rtpath-replay-');
    try {
      final relative = fixture.path.substring(location.path.length + 1);
      final original = await Directory('${fixture.path}/before').create();
      for (var i = 0; i < 16000; ++i) {
        File('${original.path}/baseline-$i').createSync();
      }
      final scan = await api.startScan(location.id, relative);
      final scope = scan.scopeId;
      final progress = await _waitFor(
        api,
        scan.taskId,
        (it) => it.entries > 0 || !_active(it),
      );
      expect(_active(progress), isTrue);
      final moved = await original.rename('${fixture.path}/after');
      await File('${moved.path}/baseline-0').delete();
      final raced = await File('${moved.path}/Raced-Final.txt')
          .writeAsString('new');
      final completed = await _waitFor(api, scan.taskId, (it) => !_active(it));
      expect(completed.state, ScanState.completed, reason: completed.message);
      expect(completed.entries, 16001);
      expect(
        (await api.find(scope, 'raced-final'))?.entries.single.path,
        raced.path,
      );
      expect((await api.find(scope, 'name:baseline-0'))?.entries, isEmpty);
      expect((await api.find(scope, 'path:before'))?.entries, isEmpty);
      final indexed = (await _allPaths(
        api,
        scope,
        '',
        SearchOrder.path,
        false,
      )).toSet();
      final actual = await fixture
          .list(recursive: true, followLinks: false)
          .map((entry) => entry.path)
          .toSet();
      expect(indexed, actual);
      debugPrint(
        'RtPath phase 4: concurrent baseline rename/create/delete reconciled against traversal',
      );
      final movedScope = await fixture.rename('${fixture.path}-moved');
      try {
        final stopped = await _waitWatch(api, scope, WatchState.stopped);
        expect(stopped.message, contains('inotify scope'));
        expect(
          (await api.find(scope, 'raced-final'))?.entries.single.path,
          raced.path,
        );
        debugPrint(
          'RtPath phase 4: moved scan root stopped watching and retained the last revision',
        );
      } finally {
        await movedScope.rename(fixture.path);
      }
    } finally {
      await fixture.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  if (const bool.fromEnvironment('RTPATH_TEST_SHARED') &&
      rootFixture.isNotEmpty) {
    testWidgets('compares shared storage events through both Android views', (
      tester,
    ) async {
      if (restarted) return;
      final shared = (await api.locations()).singleWhere(
        (it) => it.id == 'shared-primary',
      );
      expect(shared.path, '/storage/emulated/0');
      final download = await Directory('${shared.path}/Download').create();
      final fixture = await download.createTemp('rtpath-views-');
      final relative = fixture.path.substring(shared.path.length + 1);
      final raw = '/data/media/0/$relative';
      try {
        for (final tag in ['fuse-write', 'raw-write']) {
          for (final item in ['modify', 'rename-old', 'delete']) {
            await File('${fixture.path}/$tag-$item.txt').writeAsString('seed');
          }
        }
        await api.connectRoot();
        final access = await _waitRoot(api);
        expect(access.state, RootState.connected, reason: access.message);
        final ordinary = await api.startScan(shared.id, relative);
        expect(
          (await _waitFor(
            api,
            ordinary.taskId,
            (it) => !_active(it),
          )).published,
          isTrue,
        );
        final root = await api.startRootScan(raw);
        expect(
          (await _waitFor(api, root.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        final scopes = [ordinary.scopeId, root.scopeId];
        expect(
          (await api.watchStatus(ordinary.scopeId))?.state,
          WatchState.limited,
        );
        expect((await api.watchStatus(root.scopeId))?.state, WatchState.live);
        for (final scope in scopes) {
          final state = await api.watchStatus(scope);
          expect(state?.watched, 1);
          expect(state?.failures, 0);
          expect((await api.find(scope, ''))?.entries, hasLength(6));
        }

        final fuseToFuse = <bool>[];
        final fuseToRaw = <bool>[];
        final rawToFuse = <bool>[];
        final rawToRaw = <bool>[];
        Future<void> observe(
          String term,
          bool Function(SearchPage) changed,
          List<bool> fuse,
          List<bool> raw,
        ) async {
          final hits = await Future.wait(
            scopes.map((scope) => _observesChange(api, scope, term, changed)),
          );
          fuse.add(hits.first);
          raw.add(hits.last);
        }

        await File('${fixture.path}/fuse-write-create.txt')
            .writeAsString('new');
        await observe(
          'fuse-write-create',
          (page) => page.entries.singleOrNull?.bytes == 3,
          fuseToFuse,
          fuseToRaw,
        );
        await File('${fixture.path}/fuse-write-modify.txt')
            .writeAsString('changed');
        await observe(
          'fuse-write-modify',
          (page) => page.entries.singleOrNull?.bytes == 7,
          fuseToFuse,
          fuseToRaw,
        );
        await File('${fixture.path}/fuse-write-rename-old.txt')
            .rename('${fixture.path}/fuse-write-rename-new.txt');
        await observe(
          'fuse-write-rename',
          (page) =>
              page.entries.singleOrNull?.name == 'fuse-write-rename-new.txt',
          fuseToFuse,
          fuseToRaw,
        );
        await File('${fixture.path}/fuse-write-delete.txt').delete();
        await observe(
          'fuse-write-delete',
          (page) => page.entries.isEmpty,
          fuseToFuse,
          fuseToRaw,
        );

        await _runRoot("printf 'new' > '$raw/raw-write-create.txt'");
        await observe(
          'raw-write-create',
          (page) => page.entries.singleOrNull?.bytes == 3,
          rawToFuse,
          rawToRaw,
        );
        await _runRoot("printf 'changed' > '$raw/raw-write-modify.txt'");
        await observe(
          'raw-write-modify',
          (page) => page.entries.singleOrNull?.bytes == 7,
          rawToFuse,
          rawToRaw,
        );
        await _runRoot(
          "mv '$raw/raw-write-rename-old.txt' '$raw/raw-write-rename-new.txt'",
        );
        await observe(
          'raw-write-rename',
          (page) =>
              page.entries.singleOrNull?.name == 'raw-write-rename-new.txt',
          rawToFuse,
          rawToRaw,
        );
        await _runRoot("rm '$raw/raw-write-delete.txt'");
        await observe(
          'raw-write-delete',
          (page) => page.entries.isEmpty,
          rawToFuse,
          rawToRaw,
        );

        debugPrint(
          'RtPath phase 4: shared create/write/rename/delete '
          'FUSE→FUSE $fuseToFuse, FUSE→raw $fuseToRaw, raw→FUSE $rawToFuse, raw→raw $rawToRaw',
        );
        expect(fuseToFuse, everyElement(isTrue));
        expect(rawToRaw, everyElement(isTrue));
        final expected = <String, int>{
          for (final tag in ['fuse-write', 'raw-write']) ...{
            '$tag-create.txt': 3,
            '$tag-modify.txt': 7,
            '$tag-rename-new.txt': 4,
          },
        };
        final rawScan = await api.startRootScan(raw);
        expect(
          (await _waitFor(api, rawScan.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        final rawRows = (await api.find(root.scopeId, ''))!.entries;
        expect({for (final row in rawRows) row.name: row.bytes}, expected);
        await api.disconnectRoot();
        await _waitWatch(api, root.scopeId, WatchState.stopped);
        expect(
          (await api.find(
            root.scopeId,
            'raw-write-modify',
          ))?.entries.single.bytes,
          7,
        );

        final rescan = await api.startScan(shared.id, relative);
        expect(
          (await _waitFor(api, rescan.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        final rows = (await api.find(rescan.scopeId, ''))!.entries;
        expect(rows.map((row) => row.name), unorderedEquals(expected.keys));
        for (final row in rows) {
          expect(row.bytes, await File('${fixture.path}/${row.name}').length());
          if (row.name != 'raw-write-modify.txt') {
            expect(row.bytes, expected[row.name]);
          }
        }
        final fuseSize = rows
            .singleWhere((row) => row.name == 'raw-write-modify.txt')
            .bytes;
        debugPrint(
          'RtPath phase 4: shared scope rescan verified, raw write size '
          'after rescan FUSE=$fuseSize raw=${expected['raw-write-modify.txt']}',
        );
      } finally {
        await api.disconnectRoot();
        await fixture.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
  if (const bool.fromEnvironment('RTPATH_TEST_RECOVERY')) {
    _registerRecoveryTests(api, () => restarted, rootFixture);
  }
}

Future<bool> _observesChange(
  ScanApi api,
  String scope,
  String text,
  bool Function(SearchPage) changed,
) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(milliseconds: 900)) {
    final page = await api.find(scope, text);
    if (page != null && changed(page)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

Future<WatchStatus> _waitWatch(
  ScanApi api,
  String scope,
  WatchState state,
) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 5)) {
    final watch = await api.watchStatus(scope);
    if (watch?.state == state) return watch!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Watch for $scope did not reach $state');
}

Future<void> _runRoot(String command) async {
  final result = await Process.run('su', ['-c', command]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

Future<SearchPage> _waitForPage(
  ScanApi api,
  String scope,
  String text,
  bool Function(SearchPage) ready,
) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 8)) {
    final page = await api.find(scope, text);
    if (page != null && ready(page)) return page;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final watch = await api.watchStatus(scope);
  fail(
    'No live result for "$text": ${watch?.state} ${watch?.message} (seq=${watch?.sequence})',
  );
}

Future<void> _waitForWidget(
  WidgetTester tester,
  Finder finder, {
  required bool present,
}) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 5)) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty == present) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Visible results did not update for $finder');
}

Future<RootAccess> _waitRoot(ScanApi api) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 38)) {
    final access = await api.rootAccess();
    if (access.state == RootState.connected ||
        access.state == RootState.unavailable) {
      return access;
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  fail('Timed out waiting for Root authorization');
}

Future<ScanStatus> _waitForScope(ScanApi api, String scope) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < const Duration(seconds: 5)) {
    final status = await api.status();
    if (status?.scopeId == scope) return status!;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('Timed out waiting for the Root scan to start');
}

extension on ScanApi {
  Future<SearchPage?> find(
    String scope,
    String text, {
    SearchOrder order = SearchOrder.name,
    bool descending = false,
    SearchCursor? cursor,
  }) => search(scope, text, order, descending, cursor);
}

Future<List<String>> _allPaths(
  ScanApi api,
  String scope,
  String text,
  SearchOrder order,
  bool descending,
) async {
  SearchCursor? cursor;
  final paths = <String>[];
  do {
    final page = (await api.find(
      scope,
      text,
      order: order,
      descending: descending,
      cursor: cursor,
    ))!;
    expect(page.reset, isFalse);
    expect(page.entries.length, lessThanOrEqualTo(100));
    paths.addAll(page.entries.map((it) => it.path));
    cursor = page.next;
  } while (cursor != null);
  return paths;
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
