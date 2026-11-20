import 'package:flutter/material.dart';

import 'persian_digits.dart';
import 'route_engine.dart';
import 'timetable.dart';

class TimetablePage extends StatefulWidget {
  final TimetableStore store;
  final TransitStop stop;
  final List<TransitService> lines;
  final Map<int, Set<String>> directions;
  const TimetablePage({
    super.key,
    required this.store,
    required this.stop,
    required this.lines,
    required this.directions,
  });

  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  late Future<List<TimetableEntry>> entries = widget.store.forStop(
    widget.stop.id,
  );
  int day = -1;

  void _reload() =>
      setState(() => entries = widget.store.forStop(widget.stop.id));

  Future<void> _edit([TimetableEntry? entry]) async {
    final result = await showDialog<TimetableEntry>(
      context: context,
      builder: (_) => _TimetableEditor(
        stop: widget.stop.id,
        lines: widget.lines,
        directions: widget.directions,
        entry: entry,
      ),
    );
    if (result == null || !mounted) return;
    await _change(() => widget.store.save(result));
  }

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) _reload();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ذخیرهٔ تغییرات زمان‌بندی ممکن نشد.')),
        );
    }
  }

  Future<void> _delete(TimetableEntry entry) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف این زمان؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (approved == true && mounted)
      await _change(() => widget.store.delete(entry.id!));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('زمان‌بندی · ${widget.stop.name}')),
    floatingActionButton: widget.lines.isEmpty
        ? null
        : FloatingActionButton.extended(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('ثبت زمان'),
          ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('زمان‌های برنامه‌ریزی‌شده و ثبت دستی'),
              ),
              DropdownButton<int>(
                value: day,
                onChanged: (value) {
                  if (value != null) setState(() => day = value);
                },
                items: [
                  const DropdownMenuItem(value: -1, child: Text('همهٔ روزها')),
                  for (var i = 0; i < 7; i++)
                    DropdownMenuItem(value: i, child: Text(timetableDays[i])),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<TimetableEntry>>(
            future: entries,
            builder: (context, snapshot) {
              if (snapshot.hasError)
                return Center(
                  child: TextButton(
                    onPressed: _reload,
                    child: const Text('خواندن زمان‌بندی ممکن نشد. تلاش دوباره'),
                  ),
                );
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!
                  .where((entry) => day == -1 || (entry.days & (1 << day)) != 0)
                  .toList();
              if (rows.isEmpty)
                return const Center(
                  child: Text('زمانی برای این ایستگاه و روز ثبت نشده است.'),
                );
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final services = widget.lines.where(
                    (line) => line.id == row.service,
                  );
                  final label = services.isEmpty
                      ? persianDigits(row.service)
                      : services.first.label;
                  final details = [
                    if (row.arrival != null)
                      'رسیدن ${timetableTime(row.arrival!)}',
                    if (row.departure != null)
                      'حرکت ${timetableTime(row.departure!)}',
                    [
                      for (var i = 0; i < 7; i++)
                        if ((row.days & (1 << i)) != 0) timetableDays[i],
                    ].join('، '),
                    row.manual ? 'ثبت یا ویرایش دستی' : 'برنامهٔ واردشده',
                    if (row.source.isNotEmpty) row.source,
                    if (row.notes.isNotEmpty) row.notes,
                  ];
                  return ListTile(
                    title: Text(
                      '$label · ${timetableDirection(row.direction)}',
                    ),
                    subtitle: Text(details.join('\n')),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'ویرایش یا حذف زمان',
                      onSelected: (value) =>
                          value == 'edit' ? _edit(row) : _delete(row),
                      itemBuilder: (_) => [
                        if (widget.lines.isNotEmpty)
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('ویرایش'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('حذف'),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _TimetableEditor extends StatefulWidget {
  final String stop;
  final List<TransitService> lines;
  final Map<int, Set<String>> directions;
  final TimetableEntry? entry;
  const _TimetableEditor({
    required this.stop,
    required this.lines,
    required this.directions,
    this.entry,
  });

  @override
  State<_TimetableEditor> createState() => _TimetableEditorState();
}

class _TimetableEditorState extends State<_TimetableEditor> {
  late TransitService line = widget.lines.firstWhere(
    (l) => l.id == widget.entry?.service,
    orElse: () => widget.lines.first,
  );
  Set<String> get validDirections => {
    'unknown',
    ...?widget.directions[line.routeId],
  };
  late String direction = validDirections.contains(widget.entry?.direction)
      ? widget.entry!.direction
      : (validDirections.length == 2 ? validDirections.last : 'unknown');
  late int days = widget.entry?.days ?? 127;
  late String arrival = widget.entry?.arrival == null
      ? ''
      : timetableTime(widget.entry!.arrival!);
  late String departure = widget.entry?.departure == null
      ? ''
      : timetableTime(widget.entry!.departure!);
  late String source = widget.entry?.source ?? '';
  late String notes = widget.entry?.notes ?? '';
  String? error;

  void _save() {
    final arrive = timetableMinute(arrival),
        depart = timetableMinute(departure);
    if ((arrival.trim().isNotEmpty && arrive == null) ||
        (departure.trim().isNotEmpty && depart == null)) {
      setState(() => error = 'زمان را وارد کنید، مثلاً ۰۷:۳۵.');
      return;
    }
    final row = TimetableEntry(
      id: widget.entry?.id,
      stop: widget.stop,
      service: line.id,
      direction: direction,
      days: days,
      arrival: arrive,
      departure: depart,
      source: source,
      notes: notes,
    );
    try {
      row.validate();
      Navigator.pop(context, row);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.entry == null ? 'ثبت زمان' : 'ویرایش زمان'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButton<TransitService>(
          isExpanded: true,
          value: line,
          items: widget.lines
              .map(
                (value) =>
                    DropdownMenuItem(value: value, child: Text(value.label)),
              )
              .toList(),
          onChanged: (value) {
            if (value != null)
              setState(() {
                line = value;
                if (!validDirections.contains(direction)) direction = 'unknown';
              });
          },
        ),
        DropdownButton<String>(
          isExpanded: true,
          value: direction,
          items: validDirections
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(timetableDirection(value)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) setState(() => direction = value);
          },
        ),
        TextFormField(
          initialValue: arrival,
          textDirection: TextDirection.ltr,
          onChanged: (value) => arrival = value,
          decoration: const InputDecoration(
            labelText: 'ساعت رسیدن',
            hintText: '۰۷:۳۵',
          ),
        ),
        TextFormField(
          initialValue: departure,
          textDirection: TextDirection.ltr,
          onChanged: (value) => departure = value,
          decoration: const InputDecoration(
            labelText: 'ساعت حرکت',
            hintText: '۰۷:۳۷',
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          children: [
            for (var i = 0; i < 7; i++)
              FilterChip(
                label: Text(timetableDays[i]),
                selected: (days & (1 << i)) != 0,
                onSelected: (_) => setState(() => days ^= 1 << i),
              ),
          ],
        ),
        TextFormField(
          initialValue: source,
          onChanged: (value) => source = value,
          decoration: const InputDecoration(labelText: 'منبع یا تاریخ مشاهده'),
        ),
        TextFormField(
          initialValue: notes,
          onChanged: (value) => notes = value,
          decoration: const InputDecoration(labelText: 'یادداشت'),
          maxLines: 2,
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('انصراف'),
      ),
      FilledButton(onPressed: _save, child: const Text('ذخیره')),
    ],
  );
}
