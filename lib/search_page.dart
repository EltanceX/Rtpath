import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform/scan_api.g.dart';
import 'search_results.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.diagnostics});

  final Widget diagnostics;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final _api = ScanApi();
  final _relative = TextEditingController();
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _items = <SearchEntry>[];
  List<ScanLocation> _locations = [];
  List<PublishedIndex> _indexes = [];
  ScanStatus? _status;
  SearchCursor? _next;
  SearchOrder _order = SearchOrder.name;
  bool _descending = false;
  bool _fetching = false;
  bool _waitingForInput = false;
  String? _locationId;
  String? _scopeId;
  String? _error;
  String? _searchError;
  Timer? _poll;
  Timer? _debounce;
  int _loadRequest = 0;
  int _searchRequest = 0;
  bool _loading = true;
  bool _submitting = false;
  bool _configuring = true;

  ScanLocation? get _location =>
      _locations.where((location) => location.id == _locationId).firstOrNull;

  bool get _scanActive =>
      _status?.state == ScanState.running ||
      _status?.state == ScanState.cancelling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_prefetch);
    unawaited(_restore());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ++_searchRequest;
      _debounce?.cancel();
      setState(_clearResults);
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _debounce?.cancel();
    _relative.dispose();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    await _refresh(initial: true);
    if (!mounted) return;
    await _pollStatus();
  }

  Future<void> _refresh({String? preferredScope, bool initial = false}) async {
    final request = ++_loadRequest;
    try {
      final locations = await _api.locations();
      final indexes = await _api.indexes();
      if (!mounted || request != _loadRequest) return;
      final scope = preferredScope ?? _scopeId;
      setState(() {
        _loading = false;
        _locations = locations;
        _indexes = indexes;
        if (initial) _configuring = indexes.isEmpty;
        if (_location == null) _locationId = locations.firstOrNull?.id;
        _scopeId = indexes.any((index) => index.scopeId == scope)
            ? scope
            : indexes.firstOrNull?.scopeId;
      });
      await _search();
    } catch (error) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final request = ++_searchRequest;
    setState(_clearResults);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _fetch(request, null);
  }

  void _clearResults() {
    _items.clear();
    _next = null;
    _searchError = null;
    _fetching = false;
    _waitingForInput = false;
  }

  Future<void> _fetch(int request, SearchCursor? cursor) async {
    final scope = _scopeId;
    if (scope == null || _fetching) return;
    final text = _query.text;
    final order = _order;
    final descending = _descending;
    setState(() {
      _fetching = true;
      _searchError = null;
    });
    try {
      var position = cursor;
      while (mounted && request == _searchRequest) {
        final page = await _api.search(
          scope,
          text,
          order,
          descending,
          position,
        );
        if (!mounted || request != _searchRequest) return;
        if (page == null) {
          setState(() {
            _items.clear();
            _next = null;
            _searchError = '该索引范围当前不可用';
          });
          return;
        }
        if (page.reset) {
          await _search();
          return;
        }
        setState(() {
          _items.addAll(page.entries);
          _next = page.next;
        });
        if (page.entries.isNotEmpty || page.next == null) return;
        position = page.next;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (error) {
      if (!mounted || request != _searchRequest) return;
      setState(() => _searchError = _message(error));
    } finally {
      if (mounted && request == _searchRequest) {
        setState(() => _fetching = false);
      }
    }
  }

  void _prefetch() {
    if (_next != null &&
        !_fetching &&
        _searchError == null &&
        _scroll.position.extentAfter < 480 &&
        _scroll.position.pixels > 0) {
      unawaited(_fetch(_searchRequest, _next));
    }
  }

  void _queryChanged(String _) {
    _debounce?.cancel();
    ++_searchRequest;
    setState(() {
      _clearResults();
      _waitingForInput = true;
    });
    _debounce = Timer(const Duration(milliseconds: 200), _search);
  }

  Future<void> _start() async {
    final location = _location;
    if (_submitting || _scanActive || location?.canScan != true) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      final status = await _api.startScan(location!.id, _relative.text);
      if (!mounted) return;
      setState(() => _status = status);
      _schedulePoll();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel() async {
    final status = _status;
    if (status?.state != ScanState.running) return;
    try {
      final accepted = await _api.cancelScan(status!.taskId);
      if (!mounted ||
          !accepted ||
          _status?.taskId != status.taskId ||
          _status?.state != ScanState.running) {
        return;
      }
      setState(() => _status!.state = ScanState.cancelling);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(const Duration(milliseconds: 250), _pollStatus);
  }

  Future<void> _pollStatus() async {
    final previous = _status;
    try {
      final status = await _api.status();
      if (!mounted) return;
      if (_status?.taskId != previous?.taskId &&
          _status?.taskId != status?.taskId) {
        return;
      }
      setState(() => _status = status);
      if (_scanActive) {
        _schedulePoll();
      } else if (status?.published == true &&
          (previous?.taskId != status!.taskId || previous?.published != true)) {
        setState(() => _configuring = false);
        await _refresh(preferredScope: status.scopeId);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _message(error));
      if (_scanActive) _schedulePoll();
    }
  }

  Future<void> _requestAccess() async {
    try {
      await _api.requestSharedAccess();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制路径')));
    }
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();

  @override
  Widget build(BuildContext context) {
    final controls = [
      if (_configuring && _locations.isNotEmpty) ...[
        _scanControls(),
        const Divider(height: 32),
      ],
      if (_status case final status?) _scanStatus(status),
      if (_error case final error?) ...[
        Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton(
          onPressed: () {
            setState(() => _error = null);
            unawaited(_restore());
          },
          child: const Text('重新加载'),
        ),
      ],
      if (_loading) const LinearProgressIndicator(),
      if (_indexes.isNotEmpty) ...[
        DropdownButtonFormField<String>(
          key: ValueKey(_scopeId),
          initialValue: _scopeId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '索引范围'),
          items: [
            for (final index in _indexes)
              DropdownMenuItem(
                value: index.scopeId,
                child: Text(
                  index.partial ? '${index.path}（部分）' : index.path,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            setState(() => _scopeId = id);
            unawaited(_search());
          },
        ),
      ] else if (!_loading && _error == null)
        const Text('扫描一个目录以建立索引。'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('RtPath'),
        actions: [
          IconButton(
            tooltip: _configuring ? '收起扫描设置' : '打开扫描设置',
            onPressed: () => setState(() => _configuring = !_configuring),
            icon: Icon(
              _configuring
                  ? Icons.folder_open
                  : Icons.create_new_folder_outlined,
            ),
          ),
          IconButton(
            tooltip: '能力检测',
            onPressed: () => Navigator.of(
              context,
            ).push<void>(MaterialPageRoute(builder: (_) => widget.diagnostics)),
            icon: const Icon(Icons.monitor_heart_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                sliver: SliverList.list(children: controls),
              ),
              if (_indexes.isNotEmpty)
                PinnedHeaderSliver(child: _searchToolbar(context)),
              if (_items.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, index) => SearchResultRow(
                      entry: _items[index],
                      onCopy: _copyPath,
                    ),
                  ),
                ),
              if (_indexes.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: _searchFooter(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchToolbar(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: '搜索文件名',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: _queryChanged,
                  onSubmitted: (_) => unawaited(_search()),
                ),
              ),
              IconButton(
                tooltip: '搜索语法',
                icon: const Icon(Icons.help_outline),
                onPressed: () => showSearchHelp(context),
              ),
              PopupMenuButton<SearchOrder>(
                tooltip: '排序 · ${_order.label}',
                icon: const Icon(Icons.sort),
                onSelected: (order) {
                  if (_order == order) return;
                  setState(() {
                    _order = order;
                    _descending = false;
                  });
                  unawaited(_search());
                },
                itemBuilder: (context) => [
                  for (final order in SearchOrder.values)
                    CheckedPopupMenuItem(
                      value: order,
                      checked: order == _order,
                      child: Text(order.label),
                    ),
                ],
              ),
              IconButton(
                tooltip: _descending ? '改为升序' : '改为降序',
                icon: Icon(
                  _descending ? Icons.arrow_downward : Icons.arrow_upward,
                ),
                onPressed: () {
                  setState(() => _descending = !_descending);
                  unawaited(_search());
                },
              ),
            ],
          ),
          if (_items.isNotEmpty)
            SearchResultHeader(
              order: _order,
              descending: _descending,
              onSort: (order) {
                setState(() {
                  _descending = _order == order && !_descending;
                  _order = order;
                });
                unawaited(_search());
              },
            )
          else
            const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _searchFooter() {
    if (_fetching || _waitingForInput) return const LinearProgressIndicator();
    if (_searchError case final error?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error),
          if (_next != null)
            TextButton(
              onPressed: () => _fetch(_searchRequest, _next),
              child: const Text('重试加载'),
            ),
        ],
      );
    }
    if (_next != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => _fetch(_searchRequest, _next),
          child: const Text('加载更多'),
        ),
      );
    }
    return Text(_items.isEmpty ? '没有匹配的文件或目录' : '${_items.length} 条结果');
  }

  Widget _scanControls() {
    final enabled = !_scanActive && !_submitting;
    final location = _location;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey(_locationId),
          initialValue: _locationId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '扫描位置'),
          items: [
            for (final location in _locations)
              DropdownMenuItem(
                value: location.id,
                child: Text(location.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled ? (id) => setState(() => _locationId = id) : null,
        ),
        if (location != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(location.path),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _relative,
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: '相对目录（可选）',
            hintText: '例如 Download',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        if (location?.shared == true && location?.canScan == false)
          OutlinedButton(
            onPressed: _requestAccess,
            child: const Text('授予共享存储访问权限'),
          )
        else
          FilledButton(
            onPressed: enabled && location?.canScan == true ? _start : null,
            child: const Text('开始扫描'),
          ),
      ],
    );
  }

  Widget _scanStatus(ScanStatus status) {
    final label = switch (status.state) {
      ScanState.running => '正在扫描',
      ScanState.cancelling => '正在取消',
      ScanState.completed => '扫描完成',
      ScanState.partial => status.published ? '已建立部分索引' : '扫描覆盖部分目录，保留已有索引',
      ScanState.cancelled => '已取消扫描',
      ScanState.failed => '扫描失败',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_scanActive) const LinearProgressIndicator(),
          Text('$label · ${status.entries} 项'),
          if (status.issues > 0) Text('${status.issues} 处读取问题'),
          if (status.skippedMounts > 0)
            Text('跳过 ${status.skippedMounts} 处其他挂载点'),
          if (status.message case final message?) Text(message),
          if (_scanActive)
            OutlinedButton(
              onPressed: status.state == ScanState.running ? _cancel : null,
              child: const Text('取消扫描'),
            ),
        ],
      ),
    );
  }
}
