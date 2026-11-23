import 'package:flutter/material.dart';

import 'platform/scan_api.g.dart';

const _columnBreakpoint = 780.0;

extension SearchOrderLabel on SearchOrder {
  String get label => switch (this) {
    SearchOrder.name => '名称',
    SearchOrder.path => '路径',
    SearchOrder.size => '大小',
    SearchOrder.modified => '修改时间',
  };
}

class SearchResultRow extends StatelessWidget {
  const SearchResultRow({super.key, required this.entry, required this.onCopy});

  final SearchEntry entry;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(switch (entry.kind) {
      EntryKind.directory => Icons.folder_outlined,
      EntryKind.symlink => Icons.link,
      EntryKind.file => Icons.insert_drive_file_outlined,
      EntryKind.other => Icons.description_outlined,
    }, size: 20);
    final copy = IconButton(
      tooltip: '复制路径',
      onPressed: () => onCopy(entry.path),
      icon: const Icon(Icons.copy, size: 18),
    );
    final size = _size(entry.bytes);
    final date = _modified(entry.modifiedMillis);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _columnBreakpoint) {
          return _ResultColumns(
            name: Row(
              children: [
                icon,
                const SizedBox(width: 8),
                Expanded(child: _ellipsized(entry.name)),
              ],
            ),
            path: _ellipsized(entry.path),
            size: _ellipsized(size),
            modified: _ellipsized(date),
            action: copy,
          );
        }
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: icon,
          title: _ellipsized(entry.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.path, maxLines: 2, overflow: TextOverflow.ellipsis),
              _ellipsized(entry.bytes == null ? date : '$size · $date'),
            ],
          ),
          trailing: copy,
        );
      },
    );
  }
}

class SearchResultHeader extends StatelessWidget {
  const SearchResultHeader({
    super.key,
    required this.order,
    required this.descending,
    required this.onSort,
  });

  final SearchOrder order;
  final bool descending;
  final ValueChanged<SearchOrder> onSort;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < _columnBreakpoint) {
        return const SizedBox(height: 8);
      }
      Widget column(SearchOrder field) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => onSort(field),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(field.label),
              if (field == order)
                Icon(
                  descending ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 14,
                ),
            ],
          ),
        ),
      );
      return _ResultColumns(
        name: column(SearchOrder.name),
        path: column(SearchOrder.path),
        size: column(SearchOrder.size),
        modified: column(SearchOrder.modified),
        action: const SizedBox(width: 48),
      );
    },
  );
}

class _ResultColumns extends StatelessWidget {
  const _ResultColumns({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
    required this.action,
  });

  final Widget name;
  final Widget path;
  final Widget size;
  final Widget modified;
  final Widget action;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 12,
    children: [
      Expanded(flex: 4, child: name),
      Expanded(flex: 6, child: path),
      Expanded(flex: 2, child: size),
      Expanded(flex: 3, child: modified),
      action,
    ],
  );
}

Text _ellipsized(String text) =>
    Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);

String _size(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
  var amount = bytes / 1024;
  var unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return '${amount.toStringAsFixed(1)} ${units[unit]}';
}

String _modified(int millis) {
  const maximumDate = 8640000000000000;
  if (millis < -maximumDate || millis > maximumDate) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  String pad(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
}

Future<void> showSearchHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('搜索语法'),
    content: const SingleChildScrollView(
      child: Text(
        '直接输入名称的一部分，例如 项目索引。\n\n'
        'name:"Main Activity.kt" 匹配完整名称。\n'
        'prefix:Main 从名称开头匹配。\n'
        'ext:kt 只找指定扩展名。\n'
        'path:"Download/My Project" 搜索该目录内的条目。也可以填绝对路径。\n'
        'size:>100MB 筛选大小，支持 B、KB、MB、GB 及 KiB、MiB、GiB。\n\n'
        '条件可以组合，例如 prefix:Main ext:kt path:src size:>=1KiB。',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);
