import 'dart:convert';
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
class TehranTransit extends StatefulWidget {
  const TehranTransit({super.key});
  @override State<TehranTransit> createState() => _TehranTransitState();
}
class _TehranTransitState extends State<TehranTransit> {
  ThemeMode mode = ThemeMode.system;
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'تهران ترانزیت', debugShowCheckedModeBanner: false,
    locale: const Locale('fa', 'IR'), supportedLocales: const [Locale('fa','IR')],
    localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    themeMode: mode,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff087c83), scaffoldBackgroundColor: const Color(0xfff5f8f9)),
    darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xff5dd3cc)),
    home: TransitScreen(onToggleTheme: () => setState(() => mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark)));
}
class TransitFeature {
  final String mode, kind, name, ref, colour;
  final List<LatLng> points;
  TransitFeature(this.mode,this.kind,this.name,this.ref,this.colour,this.points);
}
class TransitScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const TransitScreen({super.key, required this.onToggleTheme});
  @override State<TransitScreen> createState() => _TransitScreenState();
}
class _TransitScreenState extends State<TransitScreen> {
  final search = TextEditingController();
  final map = MapController();
  Database? db;
  List<Map<String,Object?>> routes=[], stations=[];
  List<TransitFeature> osm=[];
  List<LatLng> selected=[];
  int? selectedRoute;
  String direction='outbound';
  String? error;
  bool showRoutes=true, metro=true, brt=true, bus=true, transfers=true;
  final Distance distance=const Distance();
  @override void initState() { super.initState(); init(); }
  Future<void> init() async {
    try {
      final dir=await getApplicationDocumentsDirectory();
      final file=File(p.join(dir.path,'tehran_transit_v02.sqlite'));
      if (!await file.exists()) {
        final asset=await rootBundle.load('assets/data/transit.sqlite');
        await file.writeAsBytes(asset.buffer.asUint8List(asset.offsetInBytes,asset.lengthInBytes));
      }
      db=await openDatabase(file.path,readOnly:true);
      final raw=await rootBundle.loadString('assets/data/rail_brt.geojson');
      final collection=jsonDecode(raw) as Map<String,dynamic>;
      final items=<TransitFeature>[];
      for (final f in (collection['features'] as List)) {
        try {
          final props=f['properties'] as Map<String,dynamic>;
          final geom=f['geometry'] as Map<String,dynamic>;
          final coords=geom['coordinates'] as List;
          final points=<LatLng>[];
          if (geom['type']=='Point') {
            points.add(LatLng((coords[1] as num).toDouble(),(coords[0] as num).toDouble()));
          } else if (geom['type']=='LineString') {
            for (final pt in coords) {
              points.add(LatLng((pt[1] as num).toDouble(),(pt[0] as num).toDouble()));
            }
          }
          if (points.isNotEmpty) items.add(TransitFeature(
            props['mode']?.toString()??'',props['kind']?.toString()??'',
            props['name']?.toString()??'',props['ref']?.toString()??'',
            props['colour']?.toString()??'',points));
        } catch (_) { /* Ignore malformed OSM features. */ }
      }
      osm=items;
      await load();
    } catch (e) { if (mounted) setState(()=>error=e.toString()); }
  }
  Future<void> load() async {
    if (db==null) return;
    final q='%${search.text.trim()}%';
    if (showRoutes) {
      routes=await db!.rawQuery('SELECT id,route_code,name_fa,mode FROM routes WHERE route_code LIKE ? OR name_fa LIKE ? ORDER BY CAST(route_code AS INTEGER) LIMIT 300',[q,q]);
    } else {
      stations=await db!.rawQuery('SELECT id,name_fa,latitude,longitude FROM stations WHERE name_fa LIKE ? AND latitude IS NOT NULL AND longitude IS NOT NULL ORDER BY name_fa LIMIT 250',[q]);
    }
    if (mounted) setState(() {});
  }
  Future<void> chooseRoute(int id) async {
    final rows=await db!.rawQuery('SELECT s.latitude,s.longitude FROM route_stops rs JOIN route_variants v ON v.id=rs.route_variant_id JOIN stations s ON s.id=rs.station_id WHERE v.route_id=? AND v.direction=? AND s.latitude IS NOT NULL AND s.longitude IS NOT NULL ORDER BY rs.stop_sequence',[id,direction]);
    selected=rows.map((r)=>LatLng((r['latitude'] as num).toDouble(),(r['longitude'] as num).toDouble())).toList();
    selectedRoute=id;
    if (mounted) setState(() {});
    if (selected.isNotEmpty) map.move(selected.first,12);
  }
  Future<void> stationDetails(TransitFeature f) async {
    final center=f.points.first;
    final nearby=<String>[];
    for (final other in osm) {
      if (other.kind!='station' || other.mode==f.mode) continue;
      if (distance.as(LengthUnit.Meter,center,other.points.first)<=500) {
        nearby.add('${other.mode=='metro'?'مترو':'BRT'}: ${other.name} (${distance.as(LengthUnit.Meter,center,other.points.first).round()} متر هوایی)');
      }
    }
    if (db != null) {
      final busStops=await db!.rawQuery(
        'SELECT name_fa,latitude,longitude FROM stations WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ? LIMIT 500',
        [center.latitude-0.005,center.latitude+0.005,center.longitude-0.006,center.longitude+0.006]);
      for (final stop in busStops) {
        final p=LatLng((stop['latitude'] as num).toDouble(),(stop['longitude'] as num).toDouble());
        final meters=distance.as(LengthUnit.Meter,center,p).round();
        if (meters<=400) nearby.add('اتوبوس: ${stop['name_fa']} ($meters متر هوایی)');
      }
    }
    if (!mounted) return;
    showModalBottomSheet(context:context,showDragHandle:true,isScrollControlled:true,builder:(ctx)=>SafeArea(child:Padding(
      padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(f.name,style:Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height:12),
        Text(f.mode=='metro'?'ایستگاه مترو':'ایستگاه BRT'),
        const SizedBox(height:8),
        Text(nearby.isEmpty?'ایستگاه تبادل نزدیک در داده فعلی شناسایی نشد.':nearby.take(8).join('\n')),
        const SizedBox(height:12),
        const Text('فاصله‌ها هوایی و تقریبی‌اند؛ مسیر پیاده‌روی محاسبه نشده است.',style:TextStyle(fontSize:12)),
      ]))));
  }
  bool visible(String mode)=>mode=='metro'?metro:brt;
  Color color(TransitFeature f) {
    if (f.mode=='brt') return Colors.red.shade700;
    final raw=f.colour.replaceAll('#','');
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw)) return Color(int.parse('FF$raw',radix:16));
    return Colors.blue.shade700;
  }
  @override void dispose() { search.dispose(); map.dispose(); db?.close(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final matchingOsm = search.text.trim().isEmpty ? <TransitFeature>[] :
      osm.where((f)=>f.kind=='station' && f.name.toLowerCase().contains(search.text.trim().toLowerCase())).take(20).toList();
    final osmLines=osm.where((f)=>f.kind=='route' && visible(f.mode) && f.points.length>1).toList();
    final osmStations=osm.where((f)=>f.kind=='station' && visible(f.mode)).toList();
    final transferPoints=<LatLng>[];
    if (transfers && metro && brt) {
      final ms=osmStations.where((f)=>f.mode=='metro');
      final bs=osmStations.where((f)=>f.mode=='brt').toList();
      for (final m in ms) {
        if (bs.any((b)=>distance.as(LengthUnit.Meter,m.points.first,b.points.first)<=250)) transferPoints.add(m.points.first);
      }
    }
    return Directionality(textDirection:TextDirection.rtl,child:Scaffold(
      appBar:AppBar(title:const Text('تهران ترانزیت'),centerTitle:false,actions:[
        IconButton(tooltip:'تغییر تم',icon:const Icon(Icons.dark_mode_outlined),onPressed:widget.onToggleTheme),
        IconButton(icon:const Icon(Icons.info_outline),onPressed:()=>showAboutDialog(context:context,
          applicationName:'تهران ترانزیت',children:[const Text('نسخه آزمایشی ۰.۲. داده‌های OSM ممکن است ناقص یا قدیمی باشند. مسیر اتوبوس عادی شماتیک است؛ نقاط تبادل بر اساس فاصله هوایی محاسبه می‌شوند.')]))
      ]),
      body:error!=null?Center(child:Text('خطا: $error')):db==null?
        const Center(child:CircularProgressIndicator()):
        Column(children:[
          SingleChildScrollView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.symmetric(horizontal:8),child:Row(children:[
            FilterChip(avatar:const Icon(Icons.train,size:18),label:const Text('مترو'),selected:metro,onSelected:(v)=>setState(()=>metro=v)),
            const SizedBox(width:6),
            FilterChip(avatar:const Icon(Icons.directions_bus_filled,size:18),label:const Text('BRT'),selected:brt,onSelected:(v)=>setState(()=>brt=v)),
            const SizedBox(width:6),
            FilterChip(avatar:const Icon(Icons.directions_bus,size:18),label:const Text('اتوبوس'),selected:bus,onSelected:(v)=>setState(()=>bus=v)),
            const SizedBox(width:6),
            FilterChip(avatar:const Icon(Icons.hub,size:18),label:const Text('تبادل'),selected:transfers,onSelected:(v)=>setState(()=>transfers=v)),
          ])),
          Expanded(flex:3,child:FlutterMap(
            mapController:map,
            options:const MapOptions(initialCenter:LatLng(35.6892,51.3890),initialZoom:11),
            children:[
              TileLayer(urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',userAgentPackageName:'org.tehrantransit.tehran_transit'),
              PolylineLayer(polylines:[
                ...osmLines.map((f)=>Polyline(points:f.points,color:color(f),strokeWidth:f.mode=='metro'?4:3)),
                if (bus && selected.length>1) Polyline(points:selected,color:Colors.green,strokeWidth:4),
              ]),
              MarkerLayer(markers:[
                ...osmStations.map((f)=>Marker(point:f.points.first,width:28,height:28,
                  child:GestureDetector(onTap:()=>stationDetails(f),child:Icon(
                    f.mode=='metro'?Icons.train:Icons.directions_bus,size:19,
                    color:f.mode=='metro'?Colors.blue.shade900:Colors.red.shade800)))),
                if (bus) ...selected.map((point)=>Marker(point:point,width:14,height:14,child:const Icon(Icons.circle,color:Colors.green,size:11))),
                ...transferPoints.map((point)=>Marker(point:point,width:26,height:26,
                  child:const Icon(Icons.hub,color:Colors.deepPurple,size:23))),
              ]),
              const RichAttributionWidget(attributions:[TextSourceAttribution('© OpenStreetMap contributors')]),
            ],
          )),
          Padding(padding:const EdgeInsets.fromLTRB(10,6,10,4),child:TextField(controller:search,onChanged:(_)=>load(),
            decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'کدام خط یا ایستگاه را می‌خواهید؟',isDense:true,filled:true,fillColor:Theme.of(context).colorScheme.surface,border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none)))),
          SegmentedButton<bool>(segments:const [
            ButtonSegment(value:true,label:Text('خطوط اتوبوس')),
            ButtonSegment(value:false,label:Text('ایستگاه‌های اتوبوس')),
          ],selected:{showRoutes},onSelectionChanged:(v){setState(()=>showRoutes=v.first);load();}),
          if (selectedRoute!=null) SegmentedButton<String>(segments:const [
            ButtonSegment(value:'outbound',label:Text('رفت')),ButtonSegment(value:'inbound',label:Text('برگشت'))
          ],selected:{direction},onSelectionChanged:(v){direction=v.first;chooseRoute(selectedRoute!);}),
          Expanded(flex:2,child:ListView.builder(
            itemCount:matchingOsm.length + (showRoutes?routes.length:stations.length),
            itemBuilder:(context,i) {
              if (i<matchingOsm.length) {
                final station=matchingOsm[i];
                return ListTile(dense:true,
                  leading:Icon(station.mode=='metro'?Icons.train:Icons.directions_bus,
                    color:station.mode=='metro'?Colors.blue:Colors.red),
                  title:Text(station.name),
                  subtitle:Text(station.mode=='metro'?'مترو':'BRT'),
                  trailing:const Icon(Icons.chevron_left),
                  onTap:(){map.move(station.points.first,15);stationDetails(station);});
              }
              final row=showRoutes?routes[i-matchingOsm.length]:stations[i-matchingOsm.length];
              return ListTile(dense:true,leading:Icon(showRoutes?Icons.directions_bus:Icons.place_outlined),
                title:Text(showRoutes?'خط ${row['route_code']} — ${row['name_fa']}':'${row['name_fa']}'),trailing:const Icon(Icons.chevron_left),
                onTap:(){
                  if (showRoutes) {chooseRoute(row['id'] as int);}
                  else {
                    final point=LatLng((row['latitude'] as num).toDouble(),(row['longitude'] as num).toDouble());
                    map.move(point,15);
                    setState(() {selected=[point];selectedRoute=null;});
                  }
                });
            })),
        ]),
    ));
  }
}
