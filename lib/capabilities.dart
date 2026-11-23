import 'package:flutter/services.dart';

const _channel = MethodChannel('io.github.eltancex.rtpath/capabilities');

Future<CapabilityReport> inspectCapabilities() async {
  final data = await _channel.invokeMapMethod<String, Object?>('inspect');
  if (data == null) {
    throw StateError('Android 未返回能力报告');
  }
  return CapabilityReport.fromMap(data);
}

class CapabilityReport {
  CapabilityReport.fromMap(Map<String, Object?> data)
    : androidRelease = data['androidRelease'] as String,
      androidApi = data['androidApi'] as int,
      kernelRelease = data['kernelRelease'] as String,
      nativeAbi = data['nativeAbi'] as String,
      applicationUid = data['applicationUid'] as int,
      mountNamespace = data['mountNamespace'] as String?,
      fileError = data['fileError'] as String?,
      inotifyError = data['inotifyError'] as String?,
      allFilesAccess = data['allFilesAccess'] as bool?,
      sqliteVersion =
          (data['sqlite'] as Map<Object?, Object?>)['version'] as String?,
      trigramError =
          (data['sqlite'] as Map<Object?, Object?>)['trigramError'] as String?,
      directories = (data['directories'] as List<Object?>)
          .map(
            (value) =>
                DirectoryCapability.fromMap(value as Map<Object?, Object?>),
          )
          .toList(growable: false);

  final String androidRelease;
  final int androidApi;
  final String kernelRelease;
  final String nativeAbi;
  final int applicationUid;
  final String? mountNamespace;
  final String? fileError;
  final String? inotifyError;
  final String? sqliteVersion;
  final String? trigramError;
  final bool? allFilesAccess;
  final List<DirectoryCapability> directories;
}

class DirectoryCapability {
  DirectoryCapability.fromMap(Map<Object?, Object?> data)
    : label = data['label'] as String,
      path = data['path'] as String?,
      error = data['error'] as String?,
      mount = data['mount'] as String?;

  final String label;
  final String? path;
  final String? error;
  final String? mount;
}
