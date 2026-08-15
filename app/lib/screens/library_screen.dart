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
  List<FileRecord> _files = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final files = await _service.getFiles(filterType: _filter);
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not load library: $e';
        _loading = false;
      });
    }
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
    final grouped = _groupByDate(_files);

    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterBar(),
            const Divider(height: kBorderWidth),
            Expanded(child: _buildBody(grouped)),
          ],
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
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                setState(() => _filter = type);
                _load();
              },
              selectedColor: AppColors.facebookBlue.withValues(alpha: 0.15),
              labelStyle: TextStyle(
                color: selected ? AppColors.facebookBlue : Colors.black87,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
              side: BorderSide(
                color: AppColors.facebookBlue,
                width: selected ? kBorderWidth : 1,
              ),
              backgroundColor: AppColors.background,
            ),
          );
        }).toList(),
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
      return const Center(
        child: Text('No uploads yet.', style: TextStyle(color: Colors.black54)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: grouped.entries.expand((entry) {
          return [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                entry.key,
                style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black54),
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
      ),
    );
  }
}
