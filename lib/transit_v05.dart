import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_map.dart';
import 'persian_digits.dart';
import 'raha_settings.dart';

import 'route_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TehranTransit());
}

class TehranTransit extends StatefulWidget {
  const TehranTransit({super.key});
  @override
  State<TehranTransit> createState() => _TehranTransitState();
}

class _TehranTransitState extends State<TehranTransit> {
  ThemeMode mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('raha_theme_mode');
    if (!mounted) return;
    setState(() {
      mode = value == 'dark'
          ? ThemeMode.dark
          : value == 'light'
              ? ThemeMode.light
              : ThemeMode.system;
    });
  }

  void _changeTheme(ThemeMode next) {
    setState(() => mode = next);
    SharedPreferences.getInstance().then((prefs) =>
        prefs.setString('raha_theme_mode', next.name));
  }
  @override
  Widget build(BuildContext context) {
    final light = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xff087d86),
      fontFamily: 'Vazir',
      scaffoldBackgroundColor: const Color(0xfff4f7f8),
    );
    final dark = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xff65d6d0),
      fontFamily: 'Vazir',
    );
    return MaterialApp(
      title: 'رها تهران',
      debugShowCheckedModeBanner: false,
      locale: const Locale('fa', 'IR'),
      supportedLocales: const [Locale('fa', 'IR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: light,
      darkTheme: dark,
      themeMode: mode,
      home: TransitHome(
        onTheme: () => _changeTheme(
            mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark),
        themeMode: mode,
        onThemeModeChanged: _changeTheme,
      ),
    );
  }
}

class _MapFeature {
  final String mode, kind, name, line, color, id;
  final List<LatLng> points;
  const _MapFeature(this.mode, this.kind, this.name, this.line,
      this.color, this.id, this.points);
}

class TransitHome extends StatefulWidget {
  final VoidCallback onTheme;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  const TransitHome({
    super.key,
    required this.onTheme,
    required this.themeMode,
    required this.onThemeModeChanged,
  });
  @override
  State<TransitHome> createState() => _TransitHomeState();
}

class _TransitHomeState extends State<TransitHome> {
  final MapController map = MapController();
  final TextEditingController query = TextEditingController();
  final Distance distance = const Distance();
  final OfflineMapController offlineMap = OfflineMapController();
  Timer? moveDelay;
  Database? db;
  TransitNetwork? network;
  String? error;
  List<_MapFeature> features = [];
  List<TransitService> lines = [];
  List<TransitStop> allStops = [];
  List<LatLng> selectedBusLine = [];
  TransitStop? selectedStop, origin, destination;
  TransitService? selectedService;
  TransitPlan? currentPlan;

  String panel = 'stations';
  String category = 'all';
  String routeTarget = 'origin';
  String direction = 'outbound';
  bool metro = true, brt = true, bus = true, showLines = false;
  double mapZoom = 11;
  LatLngBounds? mapBounds;

  @override
  void initState() {
    super.initState();
    offlineMap.addListener(_mapChanged);
    offlineMap.initialize();
    _load();
  }

  void _mapChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      // Refresh bundled transit data after an in-place APK update without
      // deleting user settings or previously downloaded offline map packs.
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'tehran_transit.sqlite'));
      final checksumFile = File(file.path + '.sha256');
      final asset = await rootBundle.load('assets/data/transit.sqlite');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes, asset.lengthInBytes);
      final currentChecksum = sha256.convert(bytes).toString();
      final cachedChecksum = await checksumFile.exists()
          ? await checksumFile.readAsString()
          : '';
      if (!await file.exists() || cachedChecksum != currentChecksum) {
        final pending = File(file.path + '.new');
        await pending.writeAsBytes(bytes, flush: true);
        if (await file.exists()) await file.delete();
        await pending.rename(file.path);
        await checksumFile.writeAsString(currentChecksum, flush: true);
      }
      final database = await openDatabase(file.path, readOnly: true);
      final text = await rootBundle.loadString('assets/data/rail_brt.geojson');
      final collection = jsonDecode(text) as Map<String, dynamic>;
      final parsed = <_MapFeature>[];
      for (final f in collection['features'] as List) {
        try {
          final props = f['properties'] as Map;
          final geom = f['geometry'] as Map;
          final coordinates = geom['coordinates'] as List;
          final points = <LatLng>[];
          if (geom['type'] == 'Point') {
            points.add(LatLng((coordinates[1] as num).toDouble(),
                (coordinates[0] as num).toDouble()));
          } else if (geom['type'] == 'LineString') {
            for (final pair in coordinates) {
              points.add(LatLng(
                  (pair[1] as num).toDouble(), (pair[0] as num).toDouble()));
            }
          }
          if (points.isNotEmpty) {
            parsed.add(_MapFeature(
              props['mode'].toString(),
              props['kind'].toString(),
              props['name'].toString(),
              props['ref']?.toString() ?? '',
              props['colour']?.toString() ?? '',
              props['id']?.toString() ?? '',
              points,
            ));
          }
        } catch (_) {
          // A malformed feature must not crash the whole map.
        }
      }
      final graph = await TransitNetwork.load(database, collection);
      final services = graph.services.values.toList()
        ..sort((a, b) {
          const priority = {'metro': 0, 'brt': 1, 'bus': 2};
          final mode = (priority[a.mode] ?? 9).compareTo(priority[b.mode] ?? 9);
          if (mode != 0) return mode;
          return (int.tryParse(a.code) ?? 0).compareTo(int.tryParse(b.code) ?? 0);
        });
      if (!mounted) {
        await database.close();
        return;
      }
      setState(() {
        db = database;
        features = parsed;
        network = graph;
        lines = services;
        allStops = graph.stops.values.toList()
          ..sort((a, b) {
            const priority = {'metro': 0, 'brt': 1, 'bus': 2};
            final comparison = (priority[a.mode] ?? 9)
                .compareTo(priority[b.mode] ?? 9);
            if (comparison != 0) return comparison;
            return a.name.compareTo(b.name);
          });
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  String _modeName(String mode) {
    switch (mode) {
      case 'metro':
        return 'مترو';
      case 'brt':
        return 'BRT';
      default:
        return 'اتوبوس';
    }
  }

  IconData _modeIcon(String mode) {
    switch (mode) {
      case 'metro':
        return Icons.train_rounded;
      case 'brt':
        return Icons.directions_bus_filled_rounded;
      default:
        return Icons.directions_bus_outlined;
    }
  }

  Color _modeColor(String mode) {
    if (mode == 'metro') return const Color(0xff2563eb);
    if (mode == 'brt') return const Color(0xffe05648);
    return const Color(0xff12916f);
  }

  Color _featureColor(_MapFeature f) {
    final hex = f.color.replaceAll('#', '');
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return Color(int.parse('FF' + hex, radix: 16));
    }
    return _modeColor(f.mode);
  }

  bool _mapMode(String mode) =>
      mode == 'metro' ? metro : mode == 'brt' ? brt : bus;

  void _changePanel(String value) {
    setState(() {
      panel = value;
      query.clear();
      category = 'all';
    });
  }

  String _normalized(String text) => asciiDigits(text)
      .toLowerCase()
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('‌', ' ')
      .trim();

  List<TransitStop> _matchingStops() {
    if (network == null) return [];
    final term = _normalized(query.text);
    return allStops.where((s) {
      if (category != 'all' && category != s.mode) return false;
      if (term.isEmpty) return true;
      return _normalized(s.name).contains(term) ||
          s.lines.any((line) => _normalized(line).contains(term));
    }).take(110).toList();
  }

  List<TransitService> _matchingServices() {
    final term = _normalized(query.text);
    return lines.where((s) {
      return (category == 'all' || category == s.mode) &&
          (term.isEmpty || _normalized(s.label).contains(term) ||
              _normalized(s.code).contains(term));
    }).take(130).toList();
  }

  void _mapMoved(MapCamera camera, bool hasGesture) {
    moveDelay?.cancel();
    moveDelay = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        mapBounds = camera.visibleBounds;
        mapZoom = camera.zoom;
      });
    });
  }

  Future<void> _chooseLine(TransitService service) async {
    setState(() {
      if (service.mode == 'metro') metro = true;
      if (service.mode == 'brt') brt = true;
      if (service.mode == 'bus') bus = true;
      selectedService = service;
      selectedStop = null;
      currentPlan = null;
      showLines = true;
      selectedBusLine = [];
    });
    if (service.routeId != null && db != null) {
      final rows = await db!.rawQuery(
        'SELECT s.latitude,s.longitude FROM route_stops rs '
        'JOIN route_variants v ON v.id=rs.route_variant_id '
        'JOIN stations s ON s.id=rs.station_id '
        'WHERE v.route_id=? AND v.direction=? '
        'AND s.latitude IS NOT NULL AND s.longitude IS NOT NULL '
        'ORDER BY rs.stop_sequence',
        [service.routeId, direction],
      );
      final points = rows
          .map((r) => LatLng((r['latitude'] as num).toDouble(),
              (r['longitude'] as num).toDouble()))
          .where((p) => TransitNetwork.valid(p.latitude, p.longitude))
          .toList();
      if (!mounted || selectedService?.id != service.id) return;
      setState(() => selectedBusLine = points);
      if (points.isNotEmpty) map.move(points.first, 12.5);
    } else {
      final match = features.where((f) =>
          f.kind == 'station' && f.mode == service.mode &&
          f.line.split('/').contains(service.code));
      if (match.isNotEmpty) map.move(match.first.points.first, 12);
    }
  }

  void _pickStop(TransitStop stop) {
    if (panel == 'route') {
      setState(() {
        if (stop.mode == 'metro') metro = true;
        if (stop.mode == 'brt') brt = true;
        if (stop.mode == 'bus') bus = true;
        if (routeTarget == 'origin') {
          origin = stop;
          routeTarget = 'destination';
        } else {
          destination = stop;
        }
        query.clear();
        currentPlan = origin != null && destination != null
            ? network?.plan(origin!.id, destination!.id)
            : null;
        selectedStop = stop;
        selectedService = null;
      });
      if (currentPlan != null && currentPlan!.stops.isNotEmpty) {
        map.move(currentPlan!.stops.first.point, 12);
      } else {
        map.move(stop.point, 14);
      }
      return;
    }
    setState(() {
      if (stop.mode == 'metro') metro = true;
      if (stop.mode == 'brt') brt = true;
      if (stop.mode == 'bus') bus = true;
      selectedStop = stop;
      selectedService = null;
    });
    map.move(stop.point, 15);
    _stationDetails(stop);
  }

  Future<void> _stationDetails(TransitStop stop) async {
    final nearby = network?.nearby(stop, radius: 400)
            .where((s) => s.mode != stop.mode)
            .take(6)
            .toList() ??
        [];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(_modeIcon(stop.mode),
                      color: _modeColor(stop.mode), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(stop.name,
                        style: Theme.of(ctx).textTheme.titleLarge),
                  ),
                ]),
                const SizedBox(height: 6),
                Text('ایستگاه ' + _modeName(stop.mode)),
                const SizedBox(height: 18),
                Text('خطوط عبوری',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (stop.lines.isEmpty)
                  const Text('اطلاعات خط عبوری برای این ایستگاه موجود نیست.'),
                if (stop.lines.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: stop.lines.map((line) {
                      final svc = network?.services[line];
                      return ActionChip(
                        avatar: Icon(_modeIcon(svc?.mode ?? stop.mode),
                            size: 18),
                        label: Text(persianDigits(svc?.label ?? line)),
                        onPressed: svc == null
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                _chooseLine(svc);
                              },
                      );
                    }).toList(),
                  ),
                if (stop.mode != 'metro') ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    child: ExpansionTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: const Text('ساعت‌های حرکت و رسیدن اتوبوس'),
                      subtitle: const Text('برای مشاهده، این بخش را باز کنید'),
                      children: [
                        if (stop.lines.isEmpty)
                          const ListTile(
                            title: Text('خط اتوبوسی ثبت نشده است'),
                            subtitle: Text(
                                'زمان حرکت از این ایستگاه در دسترس نیست.'),
                          ),
                        ...stop.lines.map((line) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.directions_bus_outlined),
                          title: Text(persianDigits(
                              network?.services[line]?.label ?? line)),
                          subtitle: const Text(
                              'ساعت حرکت و زمان رسیدن: در دسترس نیست'),
                        )),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 4, 16, 14),
                          child: Text(
                            'هنوز به سرویس رسمی و مجاز زمان‌بندی یا '
                            'موقعیت زنده اتوبوس متصل نیستیم؛ '
                            'ساعتی حدس زده نمی‌شود.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text('ایستگاه‌های نزدیک',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (nearby.isEmpty)
                  const Text('تبادل نزدیک در داده فعلی شناسایی نشد.'),
                ...nearby.map((near) {
                  final meters = distance
                      .as(LengthUnit.Meter, stop.point, near.point)
                      .round();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_modeIcon(near.mode),
                        color: _modeColor(near.mode)),
                    title: Text(near.name),
                    subtitle: Text(_modeName(near.mode) +
                        ' · ' + persianDigits(meters) + ' متر هوایی'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _pickStop(near);
                    },
                  );
                }),
                const SizedBox(height: 8),
                Text(
                  'فاصله‌ها هوایی و تقریبی هستند. وضعیت بهره‌برداری و مسیر '
                  'واقعی پیاده‌روی تأیید نشده‌اند.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      panel = 'route';
                      routeTarget = 'destination';
                      origin = stop;
                      destination = null;
                      currentPlan = null;
                      query.clear();
                    });
                  },
                  icon: const Icon(Icons.route),
                  label: const Text('مسیریابی از این ایستگاه'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stationTile(TransitStop stop) {
    final color = _modeColor(stop.mode);
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Icon(_modeIcon(stop.mode), color: color, size: 21),
      ),
      title: Text(stop.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_modeName(stop.mode) +
          (stop.lines.isEmpty
              ? ''
              : ' · ' +
                  stop.lines.take(3).map((s) =>
                      network?.services[s]?.label ?? s).join('، '))),
      trailing: Icon(panel == 'route' ? Icons.add_circle_outline : Icons.chevron_left),
      onTap: () => _pickStop(stop),
    );
  }

  Widget _serviceTile(TransitService service) {
    final color = _modeColor(service.mode);
    return ListTile(
      dense: true,
      leading: Icon(_modeIcon(service.mode), color: color),
      title: Text(service.label),
      subtitle: const Text('نمایش و برجسته‌سازی خط روی نقشه'),
      trailing: const Icon(Icons.chevron_left),
      selected: selectedService?.id == service.id,
      onTap: () => _chooseLine(service),
    );
  }

  Widget _routeSummary(TransitPlan route) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.alt_route_rounded),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'مسیر پیشنهادی · ' + persianDigits(route.transfers) +
                      ' تعویض خط',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text('پیاده‌روی بین ایستگاه‌ها: حدود ' +
                persianDigits(route.walkingMeters.round()) + ' متر هوایی'),
            const SizedBox(height: 6),
            ...route.legs.map((leg) {
              final svc = network?.services[leg.service];
              final title = leg.service == 'walk'
                  ? 'جابجایی پیاده (تقریبی)'
                  : svc?.label ?? leg.service;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  leg.service == 'walk'
                      ? Icons.directions_walk
                      : _modeIcon(svc?.mode ?? 'bus'),
                ),
                title: Text(title),
                subtitle: Text(
                  leg.stops.first.name + ' ← ' + leg.stops.last.name +
                      ' · ' + mathCount(leg.stops.length - 1) + ' بخش',
                ),
              );
            }),
            const Text(
              'مسیریابی آزمایشی بر اساس اتصال ایستگاه‌هاست؛ '
              'زمان واقعی، جهت پیاده‌روی و وضعیت خطوط بررسی نشده‌اند.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  String mathCount(int n) => persianDigits(n);

  Widget _pickButton(String kind, TransitStop? selected) {
    final active = routeTarget == kind;
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: () => setState(() {
          routeTarget = kind;
          query.clear();
        }),
        icon: Icon(kind == 'origin' ? Icons.trip_origin : Icons.place),
        label: Text(
          selected?.name ?? (kind == 'origin' ? 'انتخاب مبدأ' : 'انتخاب مقصد'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor:
              active ? Theme.of(context).colorScheme.primaryContainer : null,
        ),
      ),
    );
  }

  Widget _bottomPanel(ScrollController scrolling) {
    final stationResults = panel == 'lines' ? <TransitStop>[] : _matchingStops();
    final serviceResults = panel == 'lines' ? _matchingServices() : <TransitService>[];
    final activeSelection = selectedStop;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            blurRadius: 24,
            color: Colors.black.withValues(alpha: 0.10),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(children: [
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(100),
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'stations', label: Text('ایستگاه‌ها')),
            ButtonSegment(value: 'lines', label: Text('خطوط')),
            ButtonSegment(value: 'route', label: Text('مسیریابی')),
          ],
          selected: {panel},
          onSelectionChanged: (value) => _changePanel(value.first),
        ),
        if (panel == 'route') ...[
          const SizedBox(height: 10),
          Row(children: [
            _pickButton('origin', origin),
            const SizedBox(width: 8),
            _pickButton('destination', destination),
          ]),
        ],
        const SizedBox(height: 9),
        TextField(
          controller: query,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
            prefixIcon: const Icon(Icons.search),
            hintText: panel == 'route'
                ? (routeTarget == 'origin'
                    ? 'جستجوی ایستگاه مبدأ'
                    : 'جستجوی ایستگاه مقصد')
                : panel == 'lines'
                    ? 'جستجوی خط مترو، BRT یا اتوبوس'
                    : 'جستجوی ایستگاه مترو، BRT یا اتوبوس',
            suffixIcon: query.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () => setState(() => query.clear()),
                    icon: const Icon(Icons.close),
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final pair in const [
                ('all', 'همه'),
                ('metro', 'مترو'),
                ('brt', 'BRT'),
                ('bus', 'اتوبوس'),
              ]) ...[
                ChoiceChip(
                  label: Text(pair.$2),
                  selected: category == pair.$1,
                  onSelected: (_) => setState(() => category = pair.$1),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(
            controller: scrolling,
            children: [
        if (panel != 'route' && selectedService != null) ...[
          const SizedBox(height: 4),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_modeIcon(selectedService!.mode),
                color: _modeColor(selectedService!.mode)),
            title: Text(selectedService!.label),
            subtitle: const Text('خط انتخاب‌شده روی نقشه'),
            trailing: IconButton(
              tooltip: 'حذف انتخاب خط',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                selectedService = null;
                selectedBusLine = [];
              }),
            ),
          ),
          if (selectedService!.routeId != null)
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'outbound', label: Text('رفت')),
                ButtonSegment(value: 'inbound', label: Text('برگشت')),
              ],
              selected: {direction},
              onSelectionChanged: (v) {
                direction = v.first;
                _chooseLine(selectedService!);
              },
            ),
        ],
        if (panel != 'route' && activeSelection != null) ...[
          const SizedBox(height: 5),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(activeSelection.name),
            subtitle: Text(_modeName(activeSelection.mode) + ' · اطلاعات ایستگاه'),
            trailing: TextButton(
              onPressed: () => _stationDetails(activeSelection),
              child: const Text('جزئیات'),
            ),
          ),
        ],
              if (panel == 'route' && origin != null && destination != null)
                currentPlan == null
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: Text(
                          'بین این دو ایستگاه، مسیر متصل در داده فعلی پیدا نشد. '
                          'نام ایستگاه‌ها را بررسی کنید.',
                        ),
                      )
                    : _routeSummary(currentPlan!),
              if (panel == 'lines')
                ...serviceResults.map(_serviceTile)
              else
                ...stationResults.map(_stationTile),
              if (panel != 'lines' && query.text.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text(
                    'برای دیدن نتیجه دقیق‌تر، نام ایستگاه را جستجو کنید.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final graph = network;
    if (graph == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('رها تهران')),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('خطا در بارگذاری داده‌ها: ' + error!),
                ),
        ),
      );
    }

    final linesOnMap = showLines
        ? features.where((f) =>
            f.kind == 'route' &&
            _mapMode(f.mode) &&
            f.points.length > 1)
        : <_MapFeature>[];
    final stationFeatures = features.where((f) =>
        f.kind == 'station' && _mapMode(f.mode) && f.points.isNotEmpty);

    // Avoid thousands of markers at low zoom; display bus stops when zoomed in.
    final busStops = bus && mapZoom >= 13 && mapBounds != null
        ? graph.stops.values.where((s) =>
            s.mode == 'bus' && mapBounds!.contains(s.point)).take(240).toList()
        : <TransitStop>[];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('رها تهران'),
          actions: [
            IconButton(
              tooltip: offlineMap.installed
                  ? 'نقشه آفلاین فعال است'
                  : 'تنظیمات و نقشه آفلاین',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RahaSettingsPage(
                    offlineMap: offlineMap,
                    themeMode: widget.themeMode,
                    onThemeChanged: widget.onThemeModeChanged,
                  ),
                ),
              ),
              icon: Icon(offlineMap.installed
                  ? Icons.offline_pin_outlined
                  : Icons.settings_outlined),
            ),
            IconButton(
              tooltip: 'حالت روشن یا تاریک',
              onPressed: widget.onTheme,
              icon: const Icon(Icons.dark_mode_outlined),
            ),
            IconButton(
              tooltip: 'درباره داده‌های نقشه',
              onPressed: () => showAboutDialog(
                context: context,
                applicationName: 'رها تهران',
                children: const [
                  Text(
                    'نسخه آزمایشی ۰.۵. مسیرها و فاصله‌ها شماتیک و '
                    'تقریبی‌اند. داده‌ها از tehran-metro-data و '
                    'tehran-bus-data با مجوز ODbL گرفته شده‌اند.',
                  ),
                ],
              ),
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        body: Stack(children: [
          FlutterMap(
            mapController: map,
            options: MapOptions(
              initialCenter: const LatLng(35.6892, 51.3890),
              initialZoom: 11,
              onPositionChanged: _mapMoved,
            ),
            children: [
              if (offlineMap.provider != null)
                TileLayer(
                  key: ValueKey('offline-' + (offlineMap.installedEdition ?? '')),
                  tileProvider: offlineMap.provider!,
                )
              else
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'org.tehrantransit.tehran_transit',
                ),
              PolylineLayer(
                polylines: [
                  ...linesOnMap.map((f) {
                    final active = selectedService == null ||
                        selectedService!.mode != f.mode ||
                        selectedService!.code == f.line;
                    return Polyline(
                      points: f.points,
                      color: _featureColor(f).withValues(
                          alpha: active ? 0.85 : 0.20),
                      strokeWidth: active ? 4.0 : 2.0,
                    );
                  }),
                  if (selectedService != null &&
                      _mapMode(selectedService!.mode) &&
                      showLines && selectedBusLine.length > 1)
                    Polyline(
                      points: selectedBusLine,
                      color: const Color(0xff078969),
                      strokeWidth: 5,
                    ),
                  if (currentPlan != null &&
                      currentPlan!.stops.length >= 2)
                    Polyline(
                      points:
                          currentPlan!.stops.map((s) => s.point).toList(),
                      color: const Color(0xff763dd2),
                      strokeWidth: 6,
                    ),
                ],
              ),
              MarkerLayer(markers: [
                ...stationFeatures.map((f) {
                  final stopId =
                      (f.mode == 'metro' ? 'metro:' : 'bus:') + f.id;
                  final stop = graph.stops[stopId];
                  return Marker(
                    point: f.points.first,
                    width: 34,
                    height: 34,
                    child: GestureDetector(
                      onTap: stop == null ? null : () => _pickStop(stop),
                      child: Icon(
                        _modeIcon(f.mode),
                        size: 24,
                        color: _featureColor(f),
                      ),
                    ),
                  );
                }),
                ...busStops.map((stop) => Marker(
                      point: stop.point,
                      width: 28,
                      height: 28,
                      child: GestureDetector(
                        onTap: () => _pickStop(stop),
                        child: Icon(_modeIcon('bus'),
                            size: 21, color: _modeColor('bus')),
                      ),
                    )),
                if (origin != null)
                  Marker(
                    point: origin!.point,
                    width: 38,
                    height: 38,
                    child: const Icon(Icons.trip_origin,
                        size: 30, color: Color(0xff145acc)),
                  ),
                if (destination != null)
                  Marker(
                    point: destination!.point,
                    width: 38,
                    height: 38,
                    child: const Icon(Icons.location_on,
                        size: 32, color: Color(0xffd53b6b)),
                  ),
              ]),
              const RichAttributionWidget(attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ]),
            ],
          ),
          Positioned(
            top: 10,
            left: 8,
            right: 8,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                FilterChip(
                  label: const Text('مترو'),
                  avatar: const Icon(Icons.train, size: 18),
                  selected: metro,
                  onSelected: (v) => setState(() => metro = v),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('BRT'),
                  selected: brt,
                  onSelected: (v) => setState(() => brt = v),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('اتوبوس'),
                  selected: bus,
                  onSelected: (v) => setState(() => bus = v),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('نمایش خطوط'),
                  avatar: const Icon(Icons.alt_route, size: 18),
                  selected: showLines,
                  onSelected: (v) => setState(() => showLines = v),
                ),
              ]),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: .45,
            minChildSize: .39,
            maxChildSize: .86,
            snap: true,
            snapSizes: const [.45, .7],
            builder: (context, scrollController) =>
                _bottomPanel(scrollController),
          ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    moveDelay?.cancel();
    query.dispose();
    map.dispose();
    offlineMap.removeListener(_mapChanged);
    offlineMap.dispose();
    db?.close();
    super.dispose();
  }
}
