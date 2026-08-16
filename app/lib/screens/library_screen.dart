import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/file_record.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';
import '../widgets/library_row.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _service = SupabaseService.instance;

  LibraryFileType? _filter;
  String? _tagFilter;
  List<FileRecord> _files = [];
  bool _loading = true;
  String? _error;
  StreamSubscription<List<FileRecord>>? _sub;

  /// Tags present in the current type-filtered list, for the secondary
  /// filter row — derived client-side rather than a separate query, since
  /// tagging is a light, freeform label, not a real taxonomy.
  List<String> get _availableTags {
    final tags = _files.map((f) => f.tag).whereType<String>().toSet().toList();
    tags.sort();
    return tags;
  }

  List<FileRecord> get _visibleFiles {
    if (_tagFilter == null) return _files;
    return _files.where((f) => f.tag == _tagFilter).toList();
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    _sub?.cancel();
    setState(() => _loading = true);
    _sub = _service.watchFiles(filterType: _filter).listen(
      (files) {
        if (!mounted) return;
        setState(() {
          _files = files;
          _loading = false;
          _error = null;
          // A tag that no longer appears under the current type filter (or
          // was never a real tag) shouldn't silently keep filtering to
          // nothing.
          if (_tagFilter != null && !files.any((f) => f.tag == _tagFilter)) {
            _tagFilter = null;
          }
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = 'Could not load library: $e';
          _loading = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Map<String, List<FileRecord>> _groupByDate(List<FileRecord> files) {
    final groups = <String, List<FileRecord>>{};
    for (final file in files) {
      final key = DateFormat.yMMMMd().format(file.uploadedAt);
      groups.putIfAbsent(key, () => []).add(file);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByDate(_visibleFiles);

    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterBar(),
            if (_availableTags.isNotEmpty) _buildTagFilterBar(),
            const Divider(height: kBorderWidth),
            Expanded(child: _buildBody(grouped)),
          ],
        ),
      ),
    );
  }

  Widget _buildTagFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [null, ..._availableTags].map((tag) {
            final selected = _tagFilter == tag;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(tag ?? 'All tags'),
                selected: selected,
                onSelected: (_) => setState(() => _tagFilter = tag),
                selectedColor: AppColors.userBubbleBackground,
                labelStyle: TextStyle(
                  color: selected ? AppColors.medicalBlue : AppColors.mutedText(0.6),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
                side: BorderSide(color: AppColors.border, width: selected ? kBorderWidth : 1),
                backgroundColor: AppColors.surface,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    final options = <(String, LibraryFileType?)>[
      ('All', null),
      ('Docs', LibraryFileType.document),
      ('Audio', LibraryFileType.audio),
      ('Video', LibraryFileType.video),
      ('Photos', LibraryFileType.image),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        children: options.map((option) {
          final (label, type) = option;
          final selected = _filter == type;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: selected,
              onSelected: (_) {
                _filter = type;
                _subscribe();
              },
              selectedColor: AppColors.border.withValues(alpha: 0.55),
              labelStyle: TextStyle(
                color: selected ? AppColors.text : AppColors.mutedText(0.6),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
              side: BorderSide(
                color: AppColors.border,
                width: selected ? kBorderWidth : 1,
              ),
              backgroundColor: AppColors.surface,
            ),
          );
        }).toList(),
        ),
      ),
    );
  }

  Widget _buildBody(Map<String, List<FileRecord>> grouped) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (_files.isEmpty) {
      return Center(
        child: Text('No uploads yet.', style: TextStyle(color: AppColors.mutedText(0.6))),
      );
    }
    // No pull-to-refresh needed — watchFiles() is a live Realtime
    // subscription, so status changes (queued -> processing -> done) and
    // new uploads appear on their own.
    return ListView(
      children: grouped.entries.expand((entry) {
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              entry.key,
              style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.mutedText(0.6)),
            ),
          ),
          ...entry.value.map((file) => Column(
                children: [
                  LibraryRow(file: file),
                  const Divider(height: kBorderWidth, indent: 16, endIndent: 16),
                ],
              )),
        ];
      }).toList(),
    );
  }
}
