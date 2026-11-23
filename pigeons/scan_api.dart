import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/scan_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/io/github/eltancex/rtpath/scan/ScanApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'io.github.eltancex.rtpath.scan'),
    dartPackageName: 'rtpath',
  ),
)
class ScanLocation {
  ScanLocation({
    required this.id,
    required this.title,
    required this.path,
    required this.shared,
    required this.canScan,
  });

  String id;
  String title;
  String path;
  bool shared;
  bool canScan;
}

enum ScanState { running, cancelling, completed, partial, cancelled, failed }

enum RootState { idle, requesting, connected, unavailable }

class RootAccess {
  RootAccess({
    required this.state,
    required this.mounts,
    this.pid,
    this.uid,
    this.namespace,
    this.selinux,
    this.message,
  });

  RootState state;
  List<String> mounts;
  int? pid;
  int? uid;
  String? namespace;
  String? selinux;
  String? message;
}

class ScanStatus {
  ScanStatus({
    required this.taskId,
    required this.scopeId,
    required this.state,
    required this.entries,
    required this.issues,
    required this.skippedMounts,
    required this.published,
    this.message,
  });

  String taskId;
  String scopeId;
  ScanState state;
  int entries;
  int issues;
  int skippedMounts;
  bool published;
  String? message;
}

class PublishedIndex {
  PublishedIndex({
    required this.scopeId,
    required this.generation,
    required this.path,
    required this.entries,
    required this.partial,
  });

  String scopeId;
  String generation;
  String path;
  int entries;
  bool partial;
}

enum WatchState { starting, live, limited, stopped }

class WatchStatus {
  WatchStatus({
    required this.scopeId,
    required this.generation,
    required this.revision,
    required this.state,
    required this.watched,
    required this.failures,
    required this.sequence,
    this.message,
  });

  String scopeId;
  String generation;
  int revision;
  WatchState state;
  int watched;
  int failures;
  int sequence;
  String? message;
}

enum EntryKind { file, directory, symlink, other }

class SearchEntry {
  SearchEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.modifiedMillis,
    this.bytes,
  });

  String name;
  String path;
  EntryKind kind;
  int modifiedMillis;
  int? bytes;
}

enum SearchOrder { name, path, size, modified }

class SearchCursor {
  SearchCursor({
    required this.generation,
    required this.revision,
    required this.queryKey,
    required this.id,
    required this.scanCandidates,
    this.textKey,
    this.numberKey,
  });

  String generation;
  int revision;
  String queryKey;
  int id;
  bool scanCandidates;
  String? textKey;
  int? numberKey;
}

class SearchPage {
  SearchPage({
    required this.generation,
    required this.revision,
    required this.entries,
    required this.reset,
    this.next,
  });

  String generation;
  int revision;
  List<SearchEntry> entries;
  bool reset;
  SearchCursor? next;
}

@HostApi()
abstract class ScanApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<ScanLocation> locations();

  void requestSharedAccess();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<PublishedIndex> indexes();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ScanStatus startScan(String locationId, String relativePath);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<PublishedIndex> rootIndexes();

  void connectRoot();

  void disconnectRoot();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  RootAccess rootAccess();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ScanStatus startRootScan(String absolutePath);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  List<String> probeRoot(String absolutePath);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ScanStatus? status();

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  WatchStatus? watchStatus(String scopeId);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool cancelScan(String taskId);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  SearchPage? search(
    String scopeId,
    String text,
    SearchOrder order,
    bool descending,
    SearchCursor? cursor,
  );
}

@FlutterApi()
abstract class IndexUpdates {
  void changed(WatchStatus status);
}
