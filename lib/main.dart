import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

void main() { WidgetsFlutterBinding.ensureInitialized(); runApp(const TehranTransit()); }

class TehranTransit extends StatelessWidget {
  const TehranTransit({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'تهران ترانزیت', debugShowCheckedModeBanner: false,
    locale: const Locale('fa', 'IR'),
    supportedLocales: const [Locale('fa', 'IR')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff087c83)),
    home: const TransitScreen(),
  );
}

class TransitScreen extends StatefulWidget {
  const TransitScreen({super.key});
  @override State<TransitScreen> createState() => _TransitScreenState();
}
class _TransitScreenState extends State<TransitScreen> {
  final search = TextEditingController();
  final map = MapController();
  Database? db;
  List<Map<String, Object?>> routes = [];
  List<Map<String, Object?>> stations = [];
  List<LatLng> selected = [];
  int? selectedRoute;
  String direction = 'outbound';
  bool showRoutes = true;
  String? error;

  @override void initState() { super.initState(); init(); }
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'tehran_transit_01.sqlite'));
      if (!await file.exists()) {
        final asset = await rootBundle.load('assets/data/transit.sqlite');
        await file.writeAsBytes(asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes));
      }
      db = await openDatabase(file.path, readOnly: true);
      await load();
    } catch (e) { if (mounted) setState(() => error = e.toString()); }
  }
  Future<void> load() async {
    if (db == null) return;
    final q = '%${search.text.trim()}%';
    if (showRoutes) {
      routes = await db!.rawQuery('SELECT id,route_code,name_fa,mode FROM routes WHERE route_code LIKE ? OR name_fa LIKE ? ORDER BY CAST(route_code AS INTEGER) LIMIT 300', [q,q]);
    } else {
      stations = await db!.rawQuery('SELECT id,name_fa,latitude,longitude FROM stations WHERE name_fa LIKE ? AND latitude IS NOT NULL AND longitude IS NOT NULL ORDER BY name_fa LIMIT 250', [q]);
    }
    if (mounted) setState(() {});
  }
  Future<void> chooseRoute(int id) async {
    final rows = await db!.rawQuery('SELECT s.latitude,s.longitude FROM route_stops rs JOIN route_variants v ON v.id=rs.route_variant_id JOIN stations s ON s.id=rs.station_id WHERE v.route_id=? AND v.direction=? AND s.latitude IS NOT NULL AND s.longitude IS NOT NULL ORDER BY rs.stop_sequence', [id,direction]);
    selected = rows.map((r) => LatLng((r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble())).toList();
    selectedRoute = id;
    if (mounted) setState(() {});
    if (selected.isNotEmpty) map.move(selected.first, 12);
  }
  @override void dispose() { search.dispose(); map.dispose(); db?.close(); super.dispose(); }
  @override Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('تهران ترانزیت'), centerTitle: true),
      body: error != null ? Center(child: Text('خطا در بارگذاری داده‌ها: $error')) : db == null
        ? const Center(child: CircularProgressIndicator())
        : Column(children: [
          Padding(padding: const EdgeInsets.all(10), child: TextField(
            controller: search, onChanged: (_) => load(),
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'جست‌وجوی خط یا ایستگاه', border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
          )),
          SegmentedButton<bool>(segments: const [
            ButtonSegment(value: true, label: Text('خطوط'), icon: Icon(Icons.route)),
            ButtonSegment(value: false, label: Text('ایستگاه‌ها'), icon: Icon(Icons.place)),
          ], selected: {showRoutes}, onSelectionChanged: (v) { setState(() { showRoutes=v.first; }); load(); }),
          if (selectedRoute != null) Padding(padding: const EdgeInsets.all(6), child: SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'outbound', label: Text('رفت')), ButtonSegment(value: 'inbound', label: Text('برگشت'))],
            selected: {direction}, onSelectionChanged: (v) { direction=v.first; chooseRoute(selectedRoute!); },
          )),
          Expanded(flex: 3, child: FlutterMap(
            mapController: map,
            options: const MapOptions(initialCenter: LatLng(35.6892,51.3890), initialZoom: 11),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'org.tehrantransit.tehran_transit'),
              if (selected.length > 1) PolylineLayer(polylines: [Polyline(points: selected, strokeWidth: 4, color: Colors.teal)]),
              MarkerLayer(markers: selected.map((point) => Marker(point: point, width: 20, height: 20, child: const Icon(Icons.circle, color: Colors.red, size: 12))).toList()),
              const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
            ],
          )),
          Expanded(flex: 2, child: ListView.builder(
            itemCount: showRoutes ? routes.length : stations.length,
            itemBuilder: (context,i) {
              final row = showRoutes ? routes[i] : stations[i];
              return ListTile(
                dense: true,
                leading: Icon(showRoutes ? Icons.directions_bus : Icons.place_outlined),
                title: Text(showRoutes ? 'خط ${row['route_code']} — ${row['name_fa']}' : '${row['name_fa']}'),
                onTap: () {
                  if (showRoutes) { chooseRoute(row['id'] as int); }
                  else { map.move(LatLng((row['latitude'] as num).toDouble(),(row['longitude'] as num).toDouble()),15); setState(() { selected=[LatLng((row['latitude'] as num).toDouble(),(row['longitude'] as num).toDouble())]; selectedRoute=null; }); }
                },
              );
            },
          )),
        ]),
    ),
  );
}
