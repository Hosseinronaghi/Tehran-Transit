import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tehran_transit/offline_map.dart';
import 'package:tehran_transit/route_engine.dart';
import 'package:tehran_transit/timetable.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory scratch;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('raha-test-');
    SharedPreferences.setMockInitialValues({'raha_map_cadence': 'off'});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => scratch.path,
    );
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await scratch.delete(recursive: true);
  });

  test('map cadence, HTTPS and resumed response validation', () {
    expect(mapCheckInterval('weekly')!.inDays, 7);
    expect(mapCheckInterval('monthly')!.inDays, 30);
    expect(mapCheckInterval('quarterly')!.inDays, 90);
    expect(mapCheckInterval('off'), isNull);
    expect(mapHttpsUri('https://'), isNull);
    expect(mapHttpsUri('https://user@maps.example/manifest.json'), isNull);
    expect(validMapContentRange('bytes 12-99/100', 12, 100), isTrue);
    expect(validMapContentRange('bytes 13-99/100', 12, 100), isFalse);
    expect(validMapContentRange('bytes 12-89/100', 12, 100), isFalse);
    expect(MapRelease.bundled.olderThan('2026-Q4-r11'), isTrue);
    expect(MapRelease.bundled.olderThan('2025-Q4-r99'), isFalse);
  });

  test('rejects invalid map, leaves the installed map, and can recover previous map', () async {
    Future<(File, MapRelease)> build(String edition, int marker) async {
      final file = File('${scratch.path}/$edition.mbtiles');
      final sqlite = await databaseFactoryFfi.openDatabase(file.path);
      await sqlite.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
      await sqlite.execute("INSERT INTO metadata VALUES ('format', 'webp')");
      await sqlite.execute('CREATE TABLE tiles (tile_data BLOB)');
      await sqlite.insert('tiles', {
        'tile_data': Uint8List(110000)..[0] = marker,
      });
      await sqlite.close();
      final hash = (await sha256.bind(file.openRead()).first).toString();
      return (
        file,
        MapRelease(
          edition,
          'https://example.org/map.mbtiles',
          hash,
          await file.length(),
        ),
      );
    }

    final (oldFile, oldRelease) = await build('2026-Q3-r1', 1);
    final (newFile, newRelease) = await build('2026-Q4-r2', 2);
    final controller = OfflineMapController(bundledRelease: oldRelease);
    await controller.importMap(oldFile.openRead());
    expect(
      controller.installedEdition,
      oldRelease.edition,
      reason: controller.error,
    );
    await controller.importMap(Stream.value([0, 1, 0]));
    expect(controller.error, contains('مطابقت ندارد'));
    expect(controller.installedEdition, oldRelease.edition);
    controller.availableRelease = newRelease;
    await controller.importMap(newFile.openRead());
    expect(
      controller.installedEdition,
      newRelease.edition,
      reason: controller.error,
    );
    await controller.installedFile!.delete();
    controller.dispose();

    final restored = OfflineMapController(bundledRelease: oldRelease);
    await restored.initialize();
    expect(
      restored.installedEdition,
      oldRelease.edition,
      reason: restored.error,
    );
    restored.dispose();
  });

  test('offline timetable import, deduplication, edits and reload', () async {
    final parsed = parseTimetable(
      jsonEncode({
        'schema': 1,
        'entries': [
          {
            'stop': 'bus:42',
            'service': 'bus:12',
            'direction': 'outbound',
            'days': 63,
            'arrival': '۰۷:۳۵',
            'source': 'fixture',
          },
        ],
      }),
    );
    expect(parsed.single.arrival, 455);
    expect(timetableMinute('۲۴:۰۰'), isNull);
    final store = TimetableStore();
    expect(await store.importRows(parsed), 1);
    expect(await store.importRows(parsed), 0);
    final entry = (await store.forStop('bus:42')).single;
    expect(entry.manual, isFalse);
    await store.save(
      TimetableEntry(
        id: entry.id,
        stop: entry.stop,
        service: entry.service,
        direction: entry.direction,
        days: 127,
        arrival: 460,
        departure: 462,
        notes: 'observed',
        source: entry.source,
      ),
    );
    await store.dispose();

    final restored = TimetableStore();
    expect(await restored.importRows(parsed), 0);
    final edited = (await restored.forStop('bus:42')).single;
    expect(edited.manual, isTrue);
    expect(timetableTime(edited.departure!), '۰۷:۴۲');
    await restored.delete(edited.id!);
    expect(await restored.forStop('bus:42'), isEmpty);
    await restored.dispose();
  });

  test(
    'real Tehran graph preserves the long Line 1 and Line 5 segments',
    () async {
      final db = await databaseFactoryFfi.openDatabase(
        File('assets/data/transit.sqlite').absolute.path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      addTearDown(db.close);
      final geo = jsonDecode(
        await File('assets/data/rail_brt.geojson').readAsString(),
      ) as Map<String, dynamic>;
      final graph = await TransitNetwork.load(db, geo);
      for (final (from, to, service) in [
        ('شهر ری', 'پالایشگاه', 'metro:1'),
        ('وردآورد', 'گرم‌دره', 'metro:5'),
      ]) {
        final a = graph.stops.values.firstWhere(
          (s) => s.name == from && s.inMode('metro'),
        );
        final b = graph.stops.values.firstWhere(
          (s) => s.name == to && s.inMode('metro'),
        );
        expect(
          graph.edges[a.id]!.where(
            (edge) => edge.to == b.id && edge.service == service,
          ),
          isNotEmpty,
        );
        final plan = await graph.planInBackground(a.id, b.id);
        expect(plan?.legs.single.service, service);
      }
      expect(graph.directions[161], {'outbound'});
      expect(
        graph.stops.values
            .where((s) => s.inMode('brt') && s.inMode('bus'))
            .length,
        45,
      );
    },
  );
}
