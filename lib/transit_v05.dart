import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:geolocator/geolocator.dart';
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
import 'raha_colors.dart';
import 'persian_digits.dart';
import 'raha_settings.dart';

import 'route_engine.dart';
import 'timetable.dart';
import 'timetable_page.dart';

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
  final RahaColors colors = RahaColors();

  @override
  void initState() {
    super.initState();
    colors.addListener(_paletteChanged);
    colors.load();
    _restoreTheme();
  }

  void _paletteChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    colors.removeListener(_paletteChanged);
    colors.dispose();
    super.dispose();
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
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString('raha_theme_mode', next.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final light = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: colors.forPart('accent'),
      fontFamily: 'Vazir',
      scaffoldBackgroundColor: const Color(0xfff4f7f8),
    );
    final dark = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: colors.forPart('accent'),
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
          mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
        ),
        themeMode: mode,
        onThemeModeChanged: _changeTheme,
        colors: colors,
      ),
    );
  }
}

class _MapFeature {
  final String mode, kind, name, line, color, id;
  final List<LatLng> points;
  const _MapFeature(
    this.mode,
    this.kind,
    this.name,
    this.line,
    this.color,
    this.id,
    this.points,
  );
}

class TransitHome extends StatefulWidget {
  final VoidCallback onTheme;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final RahaColors colors;
  const TransitHome({
    super.key,
    required this.onTheme,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.colors,
  });
  @override
  State<TransitHome> createState() => _TransitHomeState();
}

class _TransitHomeState extends State<TransitHome> with WidgetsBindingObserver {
  final MapController map = MapController();
  final TextEditingController query = TextEditingController();
  final Distance distance = const Distance();
  final OfflineMapController offlineMap = OfflineMapController();
  final TimetableStore timetable = TimetableStore();
  bool mapReady = false,
      planning = false,
      planFailed = false,
      startingLocation = false;
  int requestLine = 0, requestPlan = 0, resultLimit = 50;
  (String?, bool, int, int)? mapPackState;
  LatLng? mapCenter;
  (String, String)? stationSearchKey, lineSearchKey;
  List<TransitStop> stationSearchResults = const [];
  List<TransitService> lineSearchResults = const [];
  Timer? moveDelay;
  StreamSubscription<Position>? locationSubscription;
  LatLng? myLocation;
  bool locationEnabled = true, followingLocation = true;
  String? locationStatus;
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
    offlineMap.addListener(_packChanged);
    widget.colors.addListener(_mapChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(offlineMap.checkWhenDue());
    _load();
    _startLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      unawaited(offlineMap.checkWhenDue());
  }

  Future<void> _startLocation({
    bool requestPermission = false,
    bool recenter = false,
  }) async {
    if (startingLocation) return;
    startingLocation = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final enabled = prefs.getBool('raha_location_enabled') ?? true;
      setState(() {
        locationEnabled = enabled;
        followingLocation =
            recenter || (prefs.getBool('raha_follow_location') ?? true);
        locationStatus = null;
        if (!enabled) myLocation = null;
      });
      if (!enabled) return;
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted)
          setState(() => locationStatus = 'مکان‌یابی دستگاه خاموش است');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (mounted &&
          requestPermission &&
          permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!mounted) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(
          () => locationStatus = permission == LocationPermission.deniedForever
              ? 'مجوز مکان‌یابی را در تنظیمات اندروید فعال کنید'
              : 'برای نمایش موقعیت، روی دکمهٔ موقعیت من بزنید',
        );
        return;
      }
      await locationSubscription?.cancel();
      if (!mounted) return;
      locationSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 15,
            ),
          ).listen(
            (position) {
              if (!mounted) return;
              final point = LatLng(position.latitude, position.longitude);
              setState(() {
                myLocation = point;
                locationStatus = null;
              });
              if (mapReady && followingLocation)
                map.move(point, mapZoom < 14 ? 14 : mapZoom);
            },
            onError: (Object error) {
              if (mounted)
                setState(() => locationStatus = 'موقعیت فعلاً در دسترس نیست');
            },
          );
    } catch (_) {
      if (mounted)
        setState(() => locationStatus = 'موقعیت فعلاً در دسترس نیست');
    } finally {
      startingLocation = false;
    }
  }

  void _packChanged() {
    final next = (
      offlineMap.installedFile?.path,
      offlineMap.preferOffline,
      offlineMap.minZoom,
      offlineMap.maxZoom,
    );
    if (next != mapPackState) {
      mapPackState = next;
      _mapChanged();
    }
  }

  void _mapChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    Database? opened;
    try {
      // Refresh bundled transit data after an in-place APK update without
      // deleting user settings or previously downloaded offline map packs.
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'tehran_transit.sqlite'));
      final checksumFile = File(file.path + '.sha256');
      final asset = await rootBundle.load('assets/data/transit.sqlite');
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final currentChecksum = sha256.convert(bytes).toString();
      final cachedChecksum = await checksumFile.exists()
          ? await checksumFile.readAsString()
          : '';
      if (!await file.exists() || cachedChecksum != currentChecksum) {
        final pending = File(file.path + '.new');
        await pending.writeAsBytes(bytes, flush: true);
        await pending.rename(file.path);
        await checksumFile.writeAsString(currentChecksum, flush: true);
      }
      final database = opened = await openDatabase(file.path, readOnly: true);
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
            points.add(
              LatLng(
                (coordinates[1] as num).toDouble(),
                (coordinates[0] as num).toDouble(),
              ),
            );
          } else if (geom['type'] == 'LineString') {
            for (final pair in coordinates) {
              points.add(
                LatLng(
                  (pair[1] as num).toDouble(),
                  (pair[0] as num).toDouble(),
                ),
              );
            }
          }
          if (points.isNotEmpty) {
            parsed.add(
              _MapFeature(
                props['mode'].toString(),
                props['kind'].toString(),
                props['name'].toString(),
                props['ref']?.toString() ?? '',
                props['colour']?.toString() ?? '',
                props['id']?.toString() ?? '',
                points,
              ),
            );
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
          return (int.tryParse(a.code) ?? 0).compareTo(
            int.tryParse(b.code) ?? 0,
          );
        });
      if (!mounted) {
        await database.close();
        return;
      }
      setState(() {
        db = database;
        error = null;
        features = parsed;
        network = graph;
        lines = services;
        allStops = graph.stops.values.toList()
          ..sort((a, b) {
            const priority = {'metro': 0, 'brt': 1, 'bus': 2};
            final comparison = (priority[a.mode] ?? 9).compareTo(
              priority[b.mode] ?? 9,
            );
            if (comparison != 0) return comparison;
            return a.name.compareTo(b.name);
          });
      });
    } catch (_) {
      await opened?.close();
      if (mounted) setState(() => error = 'خواندن دادهٔ حمل‌ونقل ممکن نشد.');
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

  Color _modeColor(String mode) => widget.colors.forPart(mode);

  Color _featureColor(_MapFeature f) {
    if (!widget.colors.useSourceLineColors) return _modeColor(f.mode);
    final hex = f.color.replaceAll('#', '');
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return Color(int.parse('FF' + hex, radix: 16));
    }
    return _modeColor(f.mode);
  }

  bool _mapMode(String mode) => mode == 'metro'
      ? metro
      : mode == 'brt'
      ? brt
      : bus;

  void _changePanel(String value) {
    setState(() {
      panel = value;
      query.clear();
      category = 'all';
      resultLimit = 50;
    });
  }

  int _searchRank(String text, String term) {
    if (text == term) return 0;
    if (text.startsWith(term)) return 1;
    return text.contains(term) ? 2 : 3;
  }

  List<TransitStop> _matchingStops() {
    final graph = network!;
    final term = normalizeTransitSearch(query.text);
    final key = (category, term);
    if (stationSearchKey == key) return stationSearchResults;
    final ranked = <(TransitStop, int)>[];
    for (final stop in allStops) {
      if (category != 'all' && !stop.inMode(category)) continue;
      var rank = term.isEmpty
          ? 0
          : _searchRank(graph.stopSearch[stop.id] ?? '', term);
      if (rank == 3 && stop.lines.any((line) => line.split(':').last == term))
        rank = 2;
      if (rank < 3) ranked.add((stop, rank));
    }
    if (term.isNotEmpty)
      ranked.sort((a, b) {
        final byRank = a.$2.compareTo(b.$2);
        return byRank != 0 ? byRank : a.$1.name.compareTo(b.$1.name);
      });
    stationSearchKey = key;
    return stationSearchResults = ranked.map((item) => item.$1).toList();
  }

  List<TransitService> _matchingServices() {
    final term = normalizeTransitSearch(query.text);
    final key = (category, term);
    if (lineSearchKey == key) return lineSearchResults;
    final matches = lines
        .where(
          (line) =>
              (category == 'all' || category == line.mode) &&
              (term.isEmpty ||
                  normalizeTransitSearch(line.label).contains(term)),
        )
        .toList();
    if (term.isNotEmpty)
      matches.sort(
        (a, b) =>
            _searchRank(a.code, term).compareTo(_searchRank(b.code, term)),
      );
    lineSearchKey = key;
    return lineSearchResults = matches;
  }

  void _mapMoved(MapCamera camera, bool hasGesture) {
    if (hasGesture) followingLocation = false;
    moveDelay?.cancel();
    moveDelay = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        mapBounds = camera.visibleBounds;
        mapZoom = camera.zoom;
        mapCenter = camera.center;
      });
    });
  }

  Future<void> _chooseLine(
    TransitService service, {
    String? selectedDirection,
  }) async {
    final ticket = ++requestLine;
    requestPlan++;
    final directions = network?.directions[service.routeId] ?? const <String>{};
    final activeDirection =
        selectedDirection ??
        (directions.contains('outbound')
            ? 'outbound'
            : directions.firstOrNull ?? 'outbound');
    setState(() {
      if (service.mode == 'metro') metro = true;
      if (service.mode == 'brt') brt = true;
      if (service.mode == 'bus') bus = true;
      selectedService = service;
      direction = activeDirection;
      planning = false;
      selectedStop = null;
      currentPlan = null;
      showLines = true;
      selectedBusLine = [];
    });
    if (service.routeId != null && db != null) {
      try {
        final rows = await db!.rawQuery(
          'SELECT s.latitude,s.longitude FROM route_stops rs '
          'JOIN route_variants v ON v.id=rs.route_variant_id '
          'JOIN stations s ON s.id=rs.station_id '
          'WHERE v.route_id=? AND v.direction=? '
          'AND s.latitude IS NOT NULL AND s.longitude IS NOT NULL '
          'ORDER BY rs.stop_sequence',
          [service.routeId, activeDirection],
        );
        final points = rows
            .map(
              (r) => LatLng(
                (r['latitude'] as num).toDouble(),
                (r['longitude'] as num).toDouble(),
              ),
            )
            .where((p) => TransitNetwork.valid(p.latitude, p.longitude))
            .toList();
        if (!mounted ||
            ticket != requestLine ||
            selectedService?.id != service.id)
          return;
        setState(() => selectedBusLine = points);
        if (mapReady && points.isNotEmpty) map.move(points.first, 12.5);
      } catch (_) {
        if (mounted && ticket == requestLine)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('خواندن مسیر این خط ممکن نشد.')),
          );
      }
    } else {
      final match = features.where(
        (f) =>
            f.kind == 'station' &&
            f.mode == service.mode &&
            f.line.split('/').contains(service.code),
      );
      if (match.isNotEmpty) map.move(match.first.points.first, 12);
    }
  }

  Future<void> _pickStop(TransitStop stop) async {
    final ticket = ++requestPlan;
    final routing = panel == 'route';
    setState(() {
      if (stop.mode == 'metro') metro = true;
      if (stop.inMode('brt')) brt = true;
      if (stop.inMode('bus')) bus = true;
      selectedStop = stop;
      selectedService = null;
      if (routing) {
        if (routeTarget == 'origin') {
          origin = stop;
          routeTarget = 'destination';
        } else {
          destination = stop;
        }
        query.clear();
        resultLimit = 50;
        currentPlan = null;
        planFailed = false;
        planning = origin != null && destination != null;
      } else {
        planning = false;
      }
    });
    if (!routing || !planning) {
      if (mapReady) map.move(stop.point, routing ? 14 : 15);
      if (!routing) await _stationDetails(stop);
      return;
    }
    TransitPlan? result;
    var failed = false;
    try {
      result = await network!.planInBackground(origin!.id, destination!.id);
    } catch (_) {
      failed = true;
    }
    if (!mounted || ticket != requestPlan) return;
    setState(() {
      currentPlan = result;
      planFailed = failed;
      planning = false;
    });
    if (mapReady)
      map.move(
        result?.stops.firstOrNull?.point ?? stop.point,
        result == null ? 14 : 12,
      );
  }

  Future<int> _importTimetable(String json) async {
    final rows = parseTimetable(json);
    final graph = network!;
    for (final row in rows) {
      final stop = graph.stops[row.stop];
      final line = graph.services[row.service];
      if (stop == null ||
          line == null ||
          line.mode == 'metro' ||
          !stop.lines.contains(row.service) ||
          (row.direction != 'unknown' &&
              !(graph.directions[line.routeId]?.contains(row.direction) ??
                  false))) {
        throw const FormatException(
          'شناسهٔ ایستگاه، خط یا جهت در دادهٔ فعلی معتبر نیست.',
        );
      }
    }
    return timetable.importRows(rows);
  }

  Future<void> _stationDetails(TransitStop stop) async {
    final nearby =
        network
            ?.nearby(stop, radius: 400)
            .where((s) => network!.canTransfer(stop, s))
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
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _modeIcon(stop.mode),
                      color: _modeColor(stop.mode),
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        stop.name,
                        style: Theme.of(ctx).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('ایستگاه ' + _modeName(stop.mode)),
                const SizedBox(height: 18),
                Text('خطوط عبوری', style: Theme.of(ctx).textTheme.titleMedium),
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
                        avatar: Icon(
                          _modeIcon(svc?.mode ?? stop.mode),
                          size: 18,
                        ),
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
                  OutlinedButton.icon(
                    icon: const Icon(Icons.schedule_outlined),
                    label: const Text('زمان رسیدن، حرکت و ثبت دستی'),
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TimetablePage(
                          store: timetable,
                          stop: stop,
                          directions: network!.directions,
                          lines: stop.lines
                              .map((line) => network!.services[line])
                              .whereType<TransitService>()
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  'ایستگاه‌های نزدیک',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (nearby.isEmpty)
                  const Text('تبادل نزدیک در داده فعلی شناسایی نشد.'),
                ...nearby.map((near) {
                  final meters = distance
                      .as(LengthUnit.Meter, stop.point, near.point)
                      .round();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _modeIcon(near.mode),
                      color: _modeColor(near.mode),
                    ),
                    title: Text(near.name),
                    subtitle: Text(
                      _modeName(near.mode) +
                          ' · ' +
                          persianDigits(meters) +
                          ' متر هوایی',
                    ),
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
                      requestPlan++;
                      currentPlan = null;
                      planning = false;
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
      subtitle: Text(
        _modeName(stop.mode) +
            (stop.lines.isEmpty
                ? ''
                : ' · ' +
                      stop.lines
                          .take(3)
                          .map((s) => network?.services[s]?.label ?? s)
                          .join('، ')),
      ),
      trailing: Icon(
        panel == 'route' ? Icons.add_circle_outline : Icons.chevron_right,
        textDirection: TextDirection.rtl,
      ),
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
      trailing: const Icon(
        Icons.chevron_right,
        textDirection: TextDirection.rtl,
      ),
      selected: selectedService?.id == service.id,
      onTap: () => _chooseLine(service),
    );
  }

  List<Widget> _groupedServices(List<TransitService> services) {
    final metroServices = services.where((s) => s.mode == 'metro').toList();
    final other = services.where((s) => s.mode != 'metro').toList();
    if (metroServices.isEmpty) return other.map(_serviceTile).toList();
    return [
      ...metroServices.map(
        (service) => ExpansionTile(
          key: ValueKey('metro-line-' + service.code),
          leading: Icon(Icons.train, color: _modeColor('metro')),
          title: Text(service.label),
          subtitle: Text(
            persianDigits(
                  allStops
                      .where(
                        (s) =>
                            s.mode == 'metro' && s.lines.contains(service.id),
                      )
                      .length,
                ) +
                ' ایستگاه',
          ),
          children: [
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('نمایش خط روی نقشه'),
              onTap: () => _chooseLine(service),
            ),
            ...allStops
                .where((s) => s.mode == 'metro' && s.lines.contains(service.id))
                .map(_stationTile),
          ],
        ),
      ),
      ...other.map(_serviceTile),
    ];
  }

  Widget _routeSummary(TransitPlan route) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.alt_route_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'مسیر پیشنهادی · ' +
                        persianDigits(route.transfers) +
                        ' تعویض خط',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'پیاده‌روی بین ایستگاه‌ها: حدود ' +
                  persianDigits(route.walkingMeters.round()) +
                  ' متر هوایی',
            ),
            const SizedBox(height: 6),
            ...route.legs.map((leg) {
              final svc = network?.services[leg.service];
              final title = leg.service == 'walk'
                  ? 'جابجایی پیاده (تقریبی)'
                  : '${svc?.label ?? leg.service}${leg.direction == null ? '' : ' · ${timetableDirection(leg.direction!)}'}';
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
                  leg.stops.first.name +
                      ' ← ' +
                      leg.stops.last.name +
                      ' · ' +
                      mathCount(leg.stops.length - 1) +
                      ' بخش',
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
          backgroundColor: active
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
        ),
      ),
    );
  }

  Widget _bottomPanel(ScrollController scrolling) {
    final stationResults = panel == 'lines'
        ? <TransitStop>[]
        : _matchingStops();
    final serviceResults = panel == 'lines'
        ? _matchingServices()
        : <TransitService>[];
    final activeSelection = selectedStop;
    final total = panel == 'lines'
        ? serviceResults.length
        : stationResults.length;
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
      child: Column(
        children: [
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
            Row(
              children: [
                _pickButton('origin', origin),
                const SizedBox(width: 8),
                _pickButton('destination', destination),
              ],
            ),
          ],
          const SizedBox(height: 9),
          TextField(
            controller: query,
            onChanged: (_) => setState(() => resultLimit = 50),
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
                      onPressed: () => setState(() {
                        query.clear();
                        resultLimit = 50;
                      }),
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
                    onSelected: (_) => setState(() {
                      category = pair.$1;
                      resultLimit = 50;
                    }),
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
                    leading: Icon(
                      _modeIcon(selectedService!.mode),
                      color: _modeColor(selectedService!.mode),
                    ),
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
                  if ((network?.directions[selectedService!.routeId]?.length ??
                          0) >
                      1)
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'outbound', label: Text('رفت')),
                        ButtonSegment(value: 'inbound', label: Text('برگشت')),
                      ],
                      selected: {direction},
                      onSelectionChanged: (v) => _chooseLine(
                        selectedService!,
                        selectedDirection: v.first,
                      ),
                    )
                  else if (selectedService!.routeId != null)
                    Text('جهت موجود: ${timetableDirection(direction)}'),
                ],
                if (panel != 'route' && activeSelection != null) ...[
                  const SizedBox(height: 5),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(activeSelection.name),
                    subtitle: Text(
                      _modeName(activeSelection.mode) + ' · اطلاعات ایستگاه',
                    ),
                    trailing: TextButton(
                      onPressed: () => _stationDetails(activeSelection),
                      child: const Text('جزئیات'),
                    ),
                  ),
                ],
                if (panel == 'route' && origin != null && destination != null)
                  planning
                      ? const LinearProgressIndicator()
                      : planFailed
                      ? const Text(
                          'محاسبهٔ مسیر ممکن نشد. ایستگاه مقصد را دوباره انتخاب کنید.',
                        )
                      : currentPlan == null
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text(
                            'بین این دو ایستگاه، مسیر متصل در داده فعلی پیدا نشد. '
                            'نام ایستگاه‌ها را بررسی کنید.',
                          ),
                        )
                      : _routeSummary(currentPlan!),
                if (panel == 'lines')
                  ..._groupedServices(serviceResults.take(resultLimit).toList())
                else
                  ...stationResults.take(resultLimit).map(_stationTile),
                if (total > resultLimit)
                  TextButton(
                    onPressed: () => setState(() => resultLimit += 50),
                    child: Text(
                      'نتایج بیشتر · ${persianDigits(total - resultLimit)} مورد دیگر',
                    ),
                  ),
                if (total == 0 && query.text.trim().isNotEmpty)
                  const ListTile(title: Text('نتیجه‌ای پیدا نشد.')),
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
        ],
      ),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!),
                      TextButton(
                        onPressed: () {
                          setState(() => error = null);
                          _load();
                        },
                        child: const Text('تلاش دوباره'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }

    final linesOnMap = showLines
        ? features.where(
            (f) => f.kind == 'route' && _mapMode(f.mode) && f.points.length > 1,
          )
        : <_MapFeature>[];
    final bounds = mapBounds;
    final stationFeatures = features.where(
      (f) =>
          f.kind == 'station' &&
          _mapMode(f.mode) &&
          f.points.isNotEmpty &&
          (bounds == null || bounds.contains(f.points.first)),
    );
    final busStops = bus && mapZoom >= 13 && bounds != null
        ? graph
              .inBounds(bounds.south, bounds.west, bounds.north, bounds.east)
              .where(
                (stop) => stop.inMode('bus') && (!brt || stop.mode != 'brt'),
              )
        : const <TransitStop>[];
    final useOffline = offlineMap.installed && offlineMap.preferOffline;
    final center = mapCenter;
    final outsideOffline =
        useOffline &&
        center != null &&
        (center.latitude < offlineMap.bounds.$2 ||
            center.latitude > offlineMap.bounds.$4 ||
            center.longitude < offlineMap.bounds.$1 ||
            center.longitude > offlineMap.bounds.$3);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('رها تهران'),
          actions: [
            IconButton(
              tooltip: useOffline
                  ? 'نقشه آفلاین فعال است'
                  : 'تنظیمات و نقشه آفلاین',
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RahaSettingsPage(
                      offlineMap: offlineMap,
                      colors: widget.colors,
                      themeMode: widget.themeMode,
                      onThemeChanged: widget.onThemeModeChanged,
                      importTimetable: _importTimetable,
                    ),
                  ),
                );
                await locationSubscription?.cancel();
                locationSubscription = null;
                if (mounted) {
                  setState(() {
                    myLocation = null;
                  });
                  await _startLocation();
                }
              },
              icon: Icon(
                offlineMap.installed
                    ? Icons.offline_pin_outlined
                    : Icons.settings_outlined,
              ),
            ),
            IconButton(
              tooltip: 'حالت روشن یا تاریک',
              onPressed: widget.onTheme,
              icon: const Icon(Icons.dark_mode_outlined),
            ),
          ],
        ),
        body: Stack(
          children: [
            FlutterMap(
              mapController: map,
              options: MapOptions(
                initialCenter: const LatLng(35.6892, 51.3890),
                initialZoom: 11,
                onMapReady: () {
                  mapReady = true;
                  if (followingLocation && myLocation != null)
                    map.move(myLocation!, 14);
                  _mapMoved(map.camera, false);
                },
                onPositionChanged: _mapMoved,
              ),
              children: [
                if (useOffline)
                  _OfflineTiles(
                    key: ValueKey(offlineMap.installedFile!.path),
                    offlineMap: offlineMap,
                  )
                else
                  const _OnlineTiles(),
                PolylineLayer(
                  polylines: [
                    ...linesOnMap.map((f) {
                      final active =
                          selectedService == null ||
                          selectedService!.mode != f.mode ||
                          selectedService!.code == f.line;
                      return Polyline(
                        points: f.points,
                        color: _featureColor(f)
                            .withValues(alpha: active ? 0.85 : 0.20),
                        strokeWidth: active ? 4.0 : 2.0,
                      );
                    }),
                    if (selectedService != null &&
                        _mapMode(selectedService!.mode) &&
                        showLines &&
                        selectedBusLine.length > 1)
                      Polyline(
                        points: selectedBusLine,
                        color: _modeColor(selectedService?.mode ?? 'bus'),
                        strokeWidth: 5,
                      ),
                    if (currentPlan != null && currentPlan!.stops.length >= 2)
                      Polyline(
                        points: currentPlan!.stops.map((s) => s.point).toList(),
                        color: widget.colors.forPart('route'),
                        strokeWidth: 6,
                      ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    if (myLocation != null && locationEnabled)
                      Marker(
                        point: myLocation!,
                        width: 42,
                        height: 42,
                        child: const Icon(
                          Icons.my_location,
                          size: 30,
                          color: Color(0xff007cda),
                        ),
                      ),
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
                    ...busStops.map(
                      (stop) => Marker(
                        point: stop.point,
                        width: 28,
                        height: 28,
                        child: GestureDetector(
                          onTap: () => _pickStop(stop),
                          child: Icon(
                            _modeIcon('bus'),
                            size: 21,
                            color: _modeColor('bus'),
                          ),
                        ),
                      ),
                    ),
                    if (origin != null)
                      Marker(
                        point: origin!.point,
                        width: 38,
                        height: 38,
                        child: const Icon(
                          Icons.trip_origin,
                          size: 30,
                          color: Color(0xff145acc),
                        ),
                      ),
                    if (destination != null)
                      Marker(
                        point: destination!.point,
                        width: 38,
                        height: 38,
                        child: const Icon(
                          Icons.location_on,
                          size: 32,
                          color: Color(0xffd53b6b),
                        ),
                      ),
                  ],
                ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('© OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
            Positioned(
              top: 61,
              left: 12,
              child: FloatingActionButton.small(
                heroTag: 'locate',
                tooltip: locationStatus ?? 'موقعیت من',
                onPressed: !locationEnabled
                    ? null
                    : () async {
                        setState(() => followingLocation = true);
                        if (myLocation != null) {
                          map.move(myLocation!, 15);
                        } else {
                          await _startLocation(
                            requestPermission: true,
                            recenter: true,
                          );
                          if (mounted && locationStatus != null)
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(locationStatus!)),
                            );
                        }
                      },
                child: Icon(
                  followingLocation
                      ? Icons.my_location
                      : Icons.location_searching,
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 8,
              right: 8,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
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
                  ],
                ),
              ),
            ),
            if (outsideOffline)
              const Positioned(
                top: 64,
                right: 12,
                child: Chip(label: Text('خارج از محدودهٔ نقشهٔ آفلاین')),
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
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    moveDelay?.cancel();
    locationSubscription?.cancel();
    unawaited(timetable.dispose());
    query.dispose();
    map.dispose();
    offlineMap.removeListener(_packChanged);
    offlineMap.dispose();
    widget.colors.removeListener(_mapChanged);
    db?.close();
    super.dispose();
  }
}

class _OfflineTiles extends StatefulWidget {
  final OfflineMapController offlineMap;
  const _OfflineTiles({super.key, required this.offlineMap});

  @override
  State<_OfflineTiles> createState() => _OfflineTilesState();
}

class _OfflineTilesState extends State<_OfflineTiles> {
  late final provider = widget.offlineMap.openProvider();
  @override
  Widget build(BuildContext context) => TileLayer(
    tileProvider: provider,
    minNativeZoom: widget.offlineMap.minZoom,
    maxNativeZoom: widget.offlineMap.maxZoom,
  );
}

class _OnlineTiles extends StatelessWidget {
  const _OnlineTiles();

  @override
  Widget build(BuildContext context) => TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'org.tehrantransit.tehran_transit',
  );
}
