part of 'scan_test.dart';

const _recoveryChannel = MethodChannel('rtpath/test-recovery');

Future<void> _setTestLimits({int watches = 0, int pending = 0}) =>
    _recoveryChannel.invokeMethod<void>('limits', {
      'watches': watches,
      'pending': pending,
    });

Future<WatchStatus> _waitRecoveryStatus(
  ScanApi api,
  String scope,
  bool Function(WatchStatus) ready,
) async {
  final clock = Stopwatch()..start();
  WatchStatus? state;
  while (clock.elapsed < const Duration(seconds: 18)) {
    state = await api.watchStatus(scope);
    if (state != null && ready(state)) return state;
    await Future<void>.delayed(const Duration(milliseconds: 12));
  }
  fail(
    'Timed out waiting for recovery on $scope. ${state?.state}: ${state?.message}',
  );
}

Future<String> _rootOutput(String command) async {
  final result = await Process.run('su', ['-c', command]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (result.stdout as String).trim();
}

String _percentiles(List<int> micros) {
  final ordered = micros.toList()..sort();
  String format(int percent) =>
      (ordered[(ordered.length * percent / 100).ceil() - 1] / 1000)
          .toStringAsFixed(2);
  return 'P50=${format(50)}ms P95=${format(95)}ms';
}

Future<void> _measureOnDevice(
  WidgetTester tester,
  ScanApi api,
  String mode,
  String scope,
  String hotName,
  Future<void> Function(bool create) mutate,
) async {
  final search = find.widgetWithText(TextField, '搜索文件名');
  final input = tester.widget<TextField>(search);
  input.controller!.text = 'name:$hotName';
  final submit = input.onSubmitted!;
  final firstScreen = <int>[];
  final firstQuery = <int>[];
  for (var n = 0; n < 100; n++) {
    final timer = Stopwatch()..start();
    final page = await api.find(scope, 'name:$hotName');
    firstQuery.add(timer.elapsedMicroseconds);
    expect(page?.entries.single.name, hotName);
    if (n < 10) {
      timer.reset();
      submit('name:$hotName');
      await _waitForWidget(tester, find.text(hotName), present: true);
      firstScreen.add(timer.elapsedMicroseconds);
    }
  }
  input.controller!.text = 'name:Stage5-Latency.txt';
  submit('name:Stage5-Latency.txt');
  await tester.pumpAndSettle();
  final database = <int>[];
  final visible = <int>[];
  for (var n = 0; n < 100; n++) {
    final create = n.isEven;
    await mutate(create);
    final timer = Stopwatch()..start();
    await _waitForPage(
      api,
      scope,
      'name:Stage5-Latency.txt',
      (page) => page.entries.isNotEmpty == create,
    );
    database.add(timer.elapsedMicroseconds);
    await _waitForWidget(
      tester,
      find.text('Stage5-Latency.txt'),
      present: create,
    );
    visible.add(timer.elapsedMicroseconds);
  }
  debugPrint(
    'RtPath phase 5: $mode hot query (n=100) ${_percentiles(firstQuery)}; '
    'first visible (n=10) ${_percentiles(firstScreen)}; '
    'create/delete DB (n=100) ${_percentiles(database)}; visible (n=100) ${_percentiles(visible)}',
  );
  debugPrint(
    'RtPath phase 5: $mode timing microseconds '
    '${jsonEncode({'query': firstQuery, 'first': firstScreen, 'db': database, 'visible': visible})}',
  );
}

Future<void> _checkOrdinaryTree(
  ScanApi api,
  String scope,
  Directory fixture,
) async {
  final expected = <String, (EntryKind, int?, int)>{};
  await for (final item in fixture.list(recursive: true, followLinks: false)) {
    final stat = await item.stat();
    final dir = stat.type == FileSystemEntityType.directory;
    expected[item.path] = (
      dir ? EntryKind.directory : EntryKind.file,
      dir ? null : stat.size,
      stat.modified.millisecondsSinceEpoch,
    );
  }
  SearchCursor? cursor;
  final actual = <String, (EntryKind, int?, int)>{};
  do {
    final page = (await api.find(
      scope,
      '',
      order: SearchOrder.path,
      cursor: cursor,
    ))!;
    expect(page.reset, isFalse);
    for (final item in page.entries) {
      expect(actual.containsKey(item.path), isFalse);
      actual[item.path] = (item.kind, item.bytes, item.modifiedMillis);
    }
    cursor = page.next;
  } while (cursor != null);
  expect(actual, expected);
}

void _registerRecoveryTests(
  ScanApi api,
  bool Function() restarted,
  String rootFixture,
) {
  testWidgets('retries a failed directory watch and repairs only that subtree', (
    tester,
  ) async {
    if (restarted()) return;
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    expect(
      location.path,
      endsWith('/io.github.eltancex.rtpath.testhost/files'),
    );
    final fixture = await Directory(location.path).createTemp('rtpath-repair-');
    final donor = await Directory(location.path)
        .createTemp('rtpath-repair-donor-');
    try {
      final healthy = await Directory('${fixture.path}/healthy').create();
      await File('${healthy.path}/Keep-Healthy.txt').writeAsString('keep');
      final started = await api.startScan(
        location.id,
        fixture.path.substring(location.path.length + 1),
      );
      final first = await _waitFor(api, started.taskId, (it) => !_active(it));
      expect(first.published, isTrue);
      final scope = started.scopeId;
      expect((await api.watchStatus(scope))?.watched, 2);
      await _setTestLimits(watches: 2);
      await File('${donor.path}/Before-Lost.txt').writeAsString('old');
      final limited = await donor.rename('${fixture.path}/limited');
      final gap = await _waitRecoveryStatus(
        api,
        scope,
        (it) => it.state == WatchState.limited && it.failures == 1,
      );
      expect(gap.generation, started.taskId);
      final old = (await api.find(scope, 'before-lost'))!.entries.single;
      await File(old.path).delete();
      await File('${limited.path}/After-Lost.txt').writeAsString('new');
      expect((await api.find(scope, 'after-lost'))?.entries, isEmpty);
      await File('${healthy.path}/Healthy-Change.txt')
          .writeAsString('stayed live');
      await _waitForPage(
        api,
        scope,
        'healthy-change',
        (it) => it.entries.singleOrNull?.bytes == 11,
      );

      final repairClock = Stopwatch()..start();
      await _setTestLimits();
      final repaired = await _waitRecoveryStatus(
        api,
        scope,
        (it) => it.state == WatchState.live && it.lastRepair != null,
      );
      expect(repaired.generation, started.taskId);
      expect(repaired.lastRepair?.relativePath, 'limited');
      expect(repaired.lastRepair?.directories, 1);
      expect(repaired.lastRepair?.entries, 2);
      expect(repaired.watched, 3);
      await _checkOrdinaryTree(api, scope, fixture);
      debugPrint(
        'RtPath phase 5: watch cap (ENOSPC injection), local repair 1 directory / 2 entries, '
        'retry waited ${repairClock.elapsedMilliseconds}ms, walk/transfer ${repaired.lastRepair!.millis}ms',
      );
    } finally {
      await _setTestLimits();
      await fixture.delete(recursive: true);
      if (await donor.exists()) await donor.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('rebuilds the range after the pending path queue overflows', (
    tester,
  ) async {
    if (restarted()) return;
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    expect(
      location.path,
      endsWith('/io.github.eltancex.rtpath.testhost/files'),
    );
    final fixture = await Directory(location.path).createTemp('rtpath-queue-');
    try {
      final last = await File('${fixture.path}/Old-Committed.txt').create();
      final relative = fixture.path.substring(location.path.length + 1);
      final initial = await api.startScan(location.id, relative);
      final scope = initial.scopeId;
      expect(
        (await _waitFor(api, initial.taskId, (it) => !_active(it))).published,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      app.main();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '搜索文件名'),
        'name:Queued-11.txt',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Queued-11.txt'), findsNothing);
      await _setTestLimits(pending: 1);
      for (var n = 0; n < 12; n++) {
        File('${fixture.path}/Queued-$n.txt').writeAsStringSync('q$n');
      }
      last.deleteSync();
      final gap = await _waitRecoveryStatus(
        api,
        scope,
        (it) =>
            it.state == WatchState.recovering &&
            it.generation == initial.taskId,
      );
      expect(gap.message, contains('inotify pending paths overflow'));
      final old = (await api.find(scope, 'old-committed'))!;
      expect(old.generation, initial.taskId);
      expect(old.entries.single.path, last.path);
      await _setTestLimits();
      final repaired = await _waitRecoveryStatus(
        api,
        scope,
        (it) => it.state == WatchState.live && it.generation != initial.taskId,
      );
      expect(repaired.lastRepair?.relativePath, '');
      expect(repaired.lastRepair?.directories, 1);
      expect(repaired.lastRepair?.entries, 12);
      await _checkOrdinaryTree(api, scope, fixture);
      await _waitForWidget(tester, find.text('Queued-11.txt'), present: true);
      debugPrint(
        'RtPath phase 5: application queue overflow, full repair 1 directory / 12 entries in ${repaired.lastRepair!.millis}ms',
      );
    } finally {
      await _setTestLimits();
      await fixture.delete(recursive: true);
    }
  });

  testWidgets(
    'permission loss preserves history until the directory is readable again',
    (tester) async {
      if (restarted()) return;
      final location = (await api.locations()).singleWhere(
        (it) => it.id == 'app-files',
      );
      final fixture = await Directory(location.path)
          .createTemp('rtpath-permissions-');
      Future<void> chmod(String mode) async {
        final result = await Process.run('/system/bin/chmod', [
          mode,
          fixture.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      try {
        await File('${fixture.path}/Keep-Permission.txt').writeAsString('keep');
        final started = await api.startScan(
          location.id,
          fixture.path.substring(location.path.length + 1),
        );
        final scope = started.scopeId;
        expect(
          (await _waitFor(api, started.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        await chmod('000');
        await _waitWatch(api, scope, WatchState.stopped);
        final blocked = await api.repair(scope);
        expect(
          (await _waitFor(api, blocked.taskId, (it) => !_active(it))).state,
          ScanState.failed,
        );
        expect(
          (await api.find(scope, 'keep-permission'))?.generation,
          started.taskId,
        );
        await chmod('700');
        await File('${fixture.path}/After-Permission.txt').writeAsString('new');
        final repair = await api.repair(scope);
        expect(
          (await _waitFor(api, repair.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        await _checkOrdinaryTree(api, scope, fixture);
        debugPrint(
          'RtPath phase 5: chmod access loss rejected repair, restoring permission allowed repair and full comparison',
        );
      } finally {
        await chmod('700');
        await fixture.delete(recursive: true);
      }
    },
  );

  if (rootFixture.isEmpty) return;
  testWidgets(
    'recovers a real kernel overflow and detects mount and RootService loss',
    (tester) async {
      if (restarted()) return;
      expect(
        rootFixture,
        matches(RegExp(r'^/data/local/tmp/rtpath-root-[a-f0-9]+$')),
      );
      final scopePath = '$rootFixture/recovery';
      final alternate = '$rootFixture/alternate';
      await _runRoot(
        "mkdir -m 700 '$scopePath' '$alternate' && printf 'old' > '$scopePath/Keep-Root.txt'",
      );
      await api.connectRoot();
      var access = await _waitRoot(api);
      expect(access.state, RootState.connected, reason: access.message);
      final servicePid = access.pid!;
      expect(servicePid, greaterThan(1));
      var mounted = false;
      try {
        final initial = await api.startRootScan(scopePath);
        final scope = initial.scopeId;
        expect(
          (await _waitFor(api, initial.taskId, (it) => !_active(it))).published,
          isTrue,
        );
        final watch = await _waitWatch(api, scope, WatchState.live);
        final fanotify = watch.message?.startsWith('fanotify · ') == true;
        final backend = fanotify ? 'fanotify' : 'inotify';
        final kernelCap = int.parse(
          await _rootOutput('cat /proc/sys/fs/$backend/max_queued_events'),
        );
        expect(kernelCap, inInclusiveRange(128, 131072));
        await _runRoot('kill -STOP $servicePid');
        try {
          if (fanotify) {
            // Fanotify can merge repeated names across the queue. Unique paths
            // outside the scope fill only its filesystem-level kernel queue.
            final flood = '$rootFixture/fanotify-overflow';
            await _runRoot(
              "mkdir -m 700 '$flood' && "
              "printf final > '$scopePath/Overflow-A.txt' && "
              ": > '$scopePath/Overflow-B.txt' || exit 1; "
              'i=0; while [ \$i -lt ${kernelCap + 1024} ]; do '
              ": > '$flood/entry-\$i' || exit 1; "
              'i=\$((i+1)); done',
            );
          } else {
            // Two alternating paths defeat inotify coalescing while the app
            // queue retains only two dirty paths.
            await _runRoot(
              'i=0; while [ \$i -lt ${kernelCap ~/ 2 + 1024} ]; do '
              ": > '$scopePath/Overflow-A.txt' && : > '$scopePath/Overflow-B.txt' || exit 1; "
              'i=\$((i+1)); done; '
              "printf final > '$scopePath/Overflow-A.txt'",
            );
          }
        } finally {
          await _runRoot('kill -CONT $servicePid');
        }
        final gap = await _waitRecoveryStatus(
          api,
          scope,
          (it) =>
              it.state == WatchState.recovering &&
              it.generation == initial.taskId,
        );
        expect(gap.message, contains('$backend kernel queue overflow'));
        expect((await api.find(scope, 'keep-root'))?.entries.single.bytes, 3);
        final repaired = await _waitRecoveryStatus(
          api,
          scope,
          (it) =>
              it.state == WatchState.live && it.generation != initial.taskId,
        );
        expect(repaired.lastRepair?.entries, 3);
        expect(repaired.message, startsWith('inotify · '));
        expect((await api.find(scope, 'overflow-a'))?.entries.single.bytes, 5);
        expect((await api.find(scope, 'overflow-b'))?.entries.single.bytes, 0);
        debugPrint(
          'RtPath phase 5: $backend kernel queue overflow at cap $kernelCap, '
          'Root repair ${repaired.lastRepair!.directories} directory / ${repaired.lastRepair!.entries} entries '
          'in ${repaired.lastRepair!.millis}ms',
        );

        await _runRoot("printf 'mount' > '$alternate/Alternate-Mount.txt'");
        await _runRoot(
          "nsenter -t $servicePid -m -- mount -o bind '$alternate' '$scopePath'",
        );
        mounted = true;
        final changedMount = await _waitWatch(api, scope, WatchState.stopped);
        expect(changedMount.message, contains('scope identity changed'));
        expect((await api.find(scope, 'keep-root'))?.entries.single.bytes, 3);
        expect((await api.find(scope, 'alternate-mount'))?.entries, isEmpty);
        final whileMounted = await api.repair(scope);
        expect(
          (await _waitFor(
            api,
            whileMounted.taskId,
            (it) => !_active(it),
          )).published,
          isTrue,
        );
        expect(
          (await api.find(scope, 'alternate-mount'))?.entries.single.bytes,
          5,
        );
        await _runRoot("nsenter -t $servicePid -m -- umount -l '$scopePath'");
        mounted = false;
        await _waitWatch(api, scope, WatchState.stopped);
        expect(
          (await api.find(scope, 'alternate-mount'))?.generation,
          whileMounted.taskId,
        );
        final afterMount = await api.repair(scope);
        expect(
          (await _waitFor(
            api,
            afterMount.taskId,
            (it) => !_active(it),
          )).published,
          isTrue,
        );
        expect(
          (await api.find(scope, 'keep-root'))?.generation,
          afterMount.taskId,
        );
        debugPrint(
          'RtPath phase 5: bind mount identity change retained history and explicit repair restored live coverage',
        );

        await _runRoot('kill -KILL $servicePid');
        final stopped = await _waitWatch(api, scope, WatchState.stopped);
        expect(stopped.message, contains('Root'));
        expect(
          (await api.find(scope, 'keep-root'))?.generation,
          afterMount.taskId,
        );
        await expectLater(api.repair(scope), throwsA(isA<PlatformException>()));
        await _runRoot("printf 'gap' > '$scopePath/Between-Services.txt'");
        await api.connectRoot();
        access = await _waitRoot(api);
        expect(access.state, RootState.connected, reason: access.message);
        expect(access.pid, isNot(servicePid));
        final recovered = await api.repair(scope);
        expect(
          (await _waitFor(
            api,
            recovered.taskId,
            (it) => !_active(it),
          )).published,
          isTrue,
        );
        expect(
          (await api.find(scope, 'between-services'))?.entries.single.bytes,
          3,
        );
        debugPrint(
          'RtPath phase 5: RootService SIGKILL preserved history, reconnect and repair reconciled offline writes',
        );
      } finally {
        try {
          if (mounted) {
            await _runRoot(
              "nsenter -t $servicePid -m -- umount -l '$scopePath'",
            );
          }
        } finally {
          await api.disconnectRoot();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  _registerMeasurement(api, restarted, rootFixture);
}

void _registerMeasurement(
  ScanApi api,
  bool Function() restarted,
  String rootFixture,
) {
  testWidgets('measures ordinary and Root scan, search and incremental refresh', (
    tester,
  ) async {
    if (restarted()) return;
    final location = (await api.locations()).singleWhere(
      (it) => it.id == 'app-files',
    );
    final fixture = await Directory(location.path)
        .createTemp('rtpath-measure-');
    try {
      for (var dir = 0; dir < 40; dir++) {
        final folder = Directory('${fixture.path}/module-$dir')..createSync();
        for (var row = 0; row < 250; row++) {
          File('${folder.path}/Build-元数据-$row.kt').createSync();
        }
      }
      const hotName = 'Stage5-Hot.txt';
      File('${fixture.path}/$hotName').createSync();
      final relative = fixture.path.substring(location.path.length + 1);
      final timer = Stopwatch()..start();
      final ordinary = await api.startScan(location.id, relative);
      final ordinaryDone = await _waitFor(
        api,
        ordinary.taskId,
        (it) => !_active(it),
      );
      expect(ordinaryDone.published, isTrue);
      debugPrint(
        'RtPath phase 5: ordinary filesystem baseline ${ordinaryDone.entries} entries in ${timer.elapsedMilliseconds}ms',
      );
      await tester.pumpWidget(const SizedBox());
      app.main();
      await tester.pumpAndSettle();
      final sample = File('${fixture.path}/Stage5-Latency.txt');
      await _measureOnDevice(
        tester,
        api,
        'ordinary',
        ordinary.scopeId,
        hotName,
        (create) async {
          if (create) {
            await sample.writeAsString('live');
          } else {
            await sample.delete();
          }
        },
      );

      await api.connectRoot();
      final access = await _waitRoot(api);
      expect(access.state, RootState.connected, reason: access.message);
      timer.reset();
      final root = await api.startRootScan(rootFixture);
      final rootDone = await _waitFor(api, root.taskId, (it) => !_active(it));
      expect(rootDone.published, isTrue);
      debugPrint(
        'RtPath phase 5: Root filesystem baseline ${rootDone.entries} entries in ${timer.elapsedMilliseconds}ms',
      );
      await tester.tap(find.byTooltip('扫描模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Root 模式'));
      await tester.pumpAndSettle();
      final closeSettings = find.byTooltip('收起扫描设置');
      if (closeSettings.evaluate().isNotEmpty) {
        await tester.tap(closeSettings);
        await tester.pumpAndSettle();
      }
      final selector = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(selector.initialValue, root.scopeId);
      await _measureOnDevice(
        tester,
        api,
        'Root',
        root.scopeId,
        'Protected-项目.txt',
        (create) => _runRoot(
          create
              ? "printf live > '$rootFixture/Stage5-Latency.txt'"
              : "rm '$rootFixture/Stage5-Latency.txt'",
        ),
      );
      final resources = await _recoveryChannel.invokeMapMethod<String, int>(
        'resources',
      );
      final rootPss = await _rootOutput(
        "grep '^Pss:' /proc/${access.pid}/smaps_rollup",
      );
      debugPrint(
        'RtPath phase 5: live resources $resources, RootService $rootPss',
      );
    } finally {
      await api.disconnectRoot();
      await fixture.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
