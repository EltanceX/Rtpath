import 'package:flutter/material.dart';

import 'capabilities.dart';
import 'search_page.dart';

void main() {
  runApp(const RtPathApp());
}

class RtPathApp extends StatelessWidget {
  const RtPathApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RtPath',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const SearchScreen(diagnostics: CapabilityPage()),
    );
  }
}

class CapabilityPage extends StatefulWidget {
  const CapabilityPage({super.key});

  @override
  State<CapabilityPage> createState() => _CapabilityPageState();
}

class _CapabilityPageState extends State<CapabilityPage> {
  late Future<CapabilityReport> _inspection;

  @override
  void initState() {
    super.initState();
    _inspection = inspectCapabilities();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RtPath 能力检测'),
        actions: [
          IconButton(
            tooltip: '重新检测',
            onPressed: () => setState(() {
              _inspection = inspectCapabilities();
            }),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<CapabilityReport>(
        future: _inspection,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText('检测失败\n${snapshot.error}'),
            );
          }
          return _ReportView(report: snapshot.requireData);
        },
      ),
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});

  final CapabilityReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('运行环境', style: theme.textTheme.titleLarge),
            ListTile(
              title: Text(
                'Android ${report.androidRelease} · API ${report.androidApi}',
              ),
              subtitle: SelectableText(
                '${report.nativeAbi} · UID ${report.applicationUid}\n'
                '${report.kernelRelease}'
                '${report.mountNamespace == null ? '' : '\n${report.mountNamespace}'}',
              ),
            ),
            const Divider(),
            Text('应用沙盒探针', style: theme.textTheme.titleLarge),
            _CheckTile(label: '原生文件读取', error: report.fileError),
            _CheckTile(label: 'inotify 变更事件', error: report.inotifyError),
            _CheckTile(
              label: 'SQLite FTS5 trigram',
              detail: report.sqliteVersion == null
                  ? null
                  : 'SQLite ${report.sqliteVersion}',
              error: report.trigramError,
            ),
            const Divider(),
            Text('普通权限可见范围', style: theme.textTheme.titleLarge),
            if (report.allFilesAccess case final bool granted)
              ListTile(title: Text('所有文件访问 · ${granted ? '已授权' : '未授权'}')),
            for (final directory in report.directories)
              _CheckTile(
                label: directory.label,
                detail: [
                  directory.path,
                  directory.mount,
                ].whereType<String>().join('\n'),
                error: directory.error,
                successLabel: '可列目录',
              ),
          ],
        ),
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  const _CheckTile({
    required this.label,
    required this.error,
    this.detail,
    this.successLabel = '通过',
  });

  final String label;
  final String? error;
  final String? detail;
  final String successLabel;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        error == null ? Icons.check_circle_outline : Icons.info_outline,
      ),
      title: Text('$label · ${error == null ? successLabel : '不可用'}'),
      subtitle: switch ((detail, error)) {
        (null, null) => null,
        (final String path, null) => SelectableText(path),
        (null, final String message) => SelectableText(message),
        (final String path, final String message) => SelectableText(
          '$path\n$message',
        ),
      },
    );
  }
}
