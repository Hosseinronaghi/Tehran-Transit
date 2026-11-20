import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'persian_digits.dart';

class TransitStop {
  final String id, name, mode;
  final LatLng point;
  final Set<String> lines;
  TransitStop(this.id, this.name, this.mode, this.point, [Set<String>? lines])
    : lines = lines ?? <String>{};

  bool inMode(String value) =>
      mode == value || lines.any((line) => line.startsWith('$value:'));
}

class TransitService {
  final String id, mode, code;
  final int? routeId;
  const TransitService(this.id, this.mode, this.code, [this.routeId]);
  String get label => persianDigits(
    mode == 'metro'
        ? 'مترو خط ' + code
        : mode == 'brt'
        ? 'BRT خط ' + code
        : 'اتوبوس خط ' + code,
  );
}

class TransitLink {
  final String to, service;
  final double meters, score;
  final String ride;
  const TransitLink(this.to, this.service, this.meters, this.score, this.ride);
}

class TransitLeg {
  final String service;
  final List<TransitStop> stops;
  final double meters;
  final String? direction;
  const TransitLeg(this.service, this.stops, this.meters, {this.direction});
}

class TransitPlan {
  final List<TransitStop> stops;
  final List<TransitLeg> legs;
  final int transfers;
  final double walkingMeters, approximateMeters;
  const TransitPlan(
    this.stops,
    this.legs,
    this.transfers,
    this.walkingMeters,
    this.approximateMeters,
  );
}

class _HeapEntry {
  final String key;
  final double score;
  const _HeapEntry(this.key, this.score);
}

class _MinHeap {
  final List<_HeapEntry> _data = [];
  bool get isNotEmpty => _data.isNotEmpty;
  void add(_HeapEntry item) {
    _data.add(item);
    var i = _data.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (_data[parent].score <= item.score) break;
      _data[i] = _data[parent];
      i = parent;
    }
    _data[i] = item;
  }

  _HeapEntry removeFirst() {
    final first = _data.first;
    final item = _data.removeLast();
    if (_data.isEmpty) return first;
    var i = 0;
    while (true) {
      var child = i * 2 + 1;
      if (child >= _data.length) break;
      if (child + 1 < _data.length &&
          _data[child + 1].score < _data[child].score)
        child++;
      if (item.score <= _data[child].score) break;
      _data[i] = _data[child];
      i = child;
    }
    _data[i] = item;
    return first;
  }
}

/// Offline graph. Connections and walking distances are schematic estimates.
class TransitNetwork {
  final Map<String, TransitStop> stops = {};
  final Map<String, TransitService> services = {};
  final Map<String, List<TransitLink>> edges = {};
  final Map<String, List<TransitStop>> _grid = {};
  final Map<int, Set<String>> directions = {};
  final Map<String, String> rideDirections = {};
  final Map<String, String> stopSearch = {};
  static const _cell = 0.004;
  final Distance distance = const Distance();

  static bool isBrt(int n) =>
      (n >= 101 && n <= 110) ||
      (n >= 121 && n <= 171) ||
      (n >= 901 && n <= 910);
  static bool valid(double lat, double lon) =>
      lat > 34 && lat < 37 && lon > 49 && lon < 54;

  String _gridKey(LatLng p) =>
      (p.latitude / _cell).floor().toString() +
      ':' +
      (p.longitude / _cell).floor().toString();
  String _pointKey(LatLng p) =>
      p.latitude.toStringAsFixed(6) + ',' + p.longitude.toStringAsFixed(6);

  void addStop(TransitStop s) {
    stops[s.id] = s;
    stopSearch[s.id] = normalizeTransitSearch(s.name);
    (_grid[_gridKey(s.point)] ??= []).add(s);
  }

  void addService(TransitService s) => services[s.id] = s;

  void addLink(
    String from,
    String to,
    String service, {
    bool both = false,
    String? ride,
  }) {
    final a = stops[from], b = stops[to];
    if (a == null || b == null || from == to) return;
    final meters = distance.as(LengthUnit.Meter, a.point, b.point);
    if (!meters.isFinite || (service == 'walk' && meters > 600)) return;
    final factor = service == 'walk'
        ? 3.2
        : service.startsWith('metro:')
        ? .65
        : service.startsWith('brt:')
        ? .90
        : 1.2;
    final score = service == 'walk'
        ? meters * factor + 280
        : math.max(meters, 85.0) * factor;
    (edges[from] ??= []).add(
      TransitLink(to, service, meters, score, ride ?? service),
    );
    if (both) {
      (edges[to] ??= []).add(
        TransitLink(from, service, meters, score, ride ?? service),
      );
    }
  }

  Iterable<TransitStop> inBounds(
    double south,
    double west,
    double north,
    double east,
  ) sync* {
    final minY = (south / _cell).floor(), maxY = (north / _cell).floor();
    final minX = (west / _cell).floor(), maxX = (east / _cell).floor();
    if ((maxY - minY + 1) * (maxX - minX + 1) > _grid.length * 2) {
      yield* stops.values.where(
        (s) =>
            s.point.latitude >= south &&
            s.point.latitude <= north &&
            s.point.longitude >= west &&
            s.point.longitude <= east,
      );
      return;
    }
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        for (final stop in _grid['$y:$x'] ?? const <TransitStop>[]) {
          if (stop.point.latitude >= south &&
              stop.point.latitude <= north &&
              stop.point.longitude >= west &&
              stop.point.longitude <= east)
            yield stop;
        }
      }
    }
  }

  List<TransitStop> nearby(TransitStop s, {double radius = 350}) {
    final latitude = radius / 110000;
    final longitude = latitude / math.cos(s.point.latitude * math.pi / 180);
    final found = <(TransitStop, double)>[];
    for (final other in inBounds(
      s.point.latitude - latitude,
      s.point.longitude - longitude,
      s.point.latitude + latitude,
      s.point.longitude + longitude,
    )) {
      if (other.id == s.id) continue;
      final meters = distance.as(LengthUnit.Meter, s.point, other.point);
      if (meters <= radius) found.add((other, meters));
    }
    found.sort((a, b) => a.$2.compareTo(b.$2));
    return found.map((item) => item.$1).toList();
  }

  bool canTransfer(TransitStop a, TransitStop b) =>
      a.mode != b.mode ||
      (a.lines.isNotEmpty &&
          b.lines.isNotEmpty &&
          !a.lines.any(b.lines.contains));

  void addWalkingTransfers() {
    final done = <String>{};
    for (final s in stops.values) {
      for (final other in nearby(s).where((o) => canTransfer(s, o)).take(8)) {
        final ids = [s.id, other.id]..sort();
        if (done.add(ids.join('|'))) {
          addLink(s.id, other.id, 'walk', both: true);
        }
      }
    }
  }

  static Future<TransitNetwork> load(
    Database db,
    Map<String, dynamic> geo,
  ) async {
    final stations = await db.rawQuery(
      'SELECT id,name_fa,latitude,longitude FROM stations '
      'WHERE latitude IS NOT NULL AND longitude IS NOT NULL',
    );
    final routes = await db.rawQuery('SELECT id,route_code,mode FROM routes');
    final seq = await db.rawQuery(
      'SELECT rs.route_variant_id,rs.station_id,rs.stop_sequence,'
      'r.route_code,v.route_id,v.direction FROM route_stops rs JOIN route_variants v '
      'ON v.id=rs.route_variant_id JOIN routes r ON r.id=v.route_id '
      'ORDER BY rs.route_variant_id,rs.stop_sequence',
    );
    return compute(_build, (
      stations,
      routes,
      seq,
      geo,
    ), debugLabel: 'transit-graph');
  }

  static TransitNetwork _build(
    (
      List<Map<String, Object?>>,
      List<Map<String, Object?>>,
      List<Map<String, Object?>>,
      Map<String, dynamic>,
    )
    input,
  ) {
    final (stations, routes, seq, geo) = input;
    final n = TransitNetwork();
    final brtIds = <int>{};
    for (final row in seq) {
      if (isBrt(int.tryParse(row['route_code'].toString()) ?? 0)) {
        brtIds.add(row['station_id'] as int);
      }
    }
    for (final row in stations) {
      final lat = (row['latitude'] as num).toDouble();
      final lon = (row['longitude'] as num).toDouble();
      if (!valid(lat, lon)) continue;
      final id = row['id'] as int;
      n.addStop(
        TransitStop(
          'bus:' + id.toString(),
          row['name_fa'].toString(),
          brtIds.contains(id) ? 'brt' : 'bus',
          LatLng(lat, lon),
        ),
      );
    }
    for (final route in routes) {
      final code = route['route_code'].toString();
      final mode = isBrt(int.tryParse(code) ?? 0) ? 'brt' : 'bus';
      n.addService(
        TransitService(mode + ':' + code, mode, code, route['id'] as int),
      );
    }

    final metroByCoord = <String, String>{};
    final features = geo['features'] as List;
    for (final feature in features) {
      final props = feature['properties'] as Map;
      final geom = feature['geometry'] as Map;
      if (props['mode'] != 'metro' || props['kind'] != 'station') continue;
      final c = geom['coordinates'] as List;
      final pos = LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
      final id = 'metro:' + props['id'].toString();
      final lines = props['ref'].toString().split('/');
      n.addStop(
        TransitStop(
          id,
          props['name'].toString(),
          'metro',
          pos,
          lines.where((s) => s.isNotEmpty).map((s) => 'metro:' + s).toSet(),
        ),
      );
      metroByCoord[n._pointKey(pos)] = id;
      for (final code in lines.where((s) => s.isNotEmpty)) {
        n.addService(TransitService('metro:' + code, 'metro', code));
      }
    }
    for (final feature in features) {
      final props = feature['properties'] as Map;
      final geom = feature['geometry'] as Map;
      if (props['mode'] != 'metro' || props['kind'] != 'route') continue;
      final c = geom['coordinates'] as List;
      if (c.length < 2) continue;
      final a = c.first as List, b = c.last as List;
      final from =
          metroByCoord[n._pointKey(
            LatLng((a[1] as num).toDouble(), (a[0] as num).toDouble()),
          )];
      final to =
          metroByCoord[n._pointKey(
            LatLng((b[1] as num).toDouble(), (b[0] as num).toDouble()),
          )];
      if (from != null && to != null) {
        n.addLink(from, to, 'metro:' + props['ref'].toString(), both: true);
      }
    }

    Map<String, Object?>? previous;
    for (final row in seq) {
      final id = 'bus:' + row['station_id'].toString();
      final code = row['route_code'].toString();
      final routeId = row['route_id'] as int;
      final direction = row['direction'] as String;
      (n.directions[routeId] ??= {}).add(direction);
      final service = (isBrt(int.tryParse(code) ?? 0) ? 'brt:' : 'bus:') + code;
      final ride = service + ':' + row['route_variant_id'].toString();
      n.rideDirections[ride] = direction;
      n.stops[id]?.lines.add(service);
      if (previous != null &&
          previous['route_variant_id'] == row['route_variant_id']) {
        n.addLink(
          'bus:' + previous['station_id'].toString(),
          id,
          service,
          ride: ride,
        );
      }
      previous = row;
    }
    n.addWalkingTransfers();
    return n;
  }

  Future<TransitPlan?> planInBackground(String from, String to) =>
      compute(_plan, (this, from, to), debugLabel: 'transit-route');

  static TransitPlan? _plan((TransitNetwork, String, String) input) =>
      input.$1.plan(input.$2, input.$3);

  /// Dijkstra over station and most recent ride, with transfer penalties.
  /// Not a claim about live travel times or actual walking directions.
  TransitPlan? plan(String from, String to) {
    if (!stops.containsKey(from) || !stops.containsKey(to)) return null;
    if (from == to) return TransitPlan([stops[from]!], [], 0, 0, 0);
    const sep = '\u001f';
    final start = from + sep;
    final best = <String, double>{start: 0};
    final parent = <String, String>{};
    final via = <String, TransitLink>{};
    final heap = _MinHeap()..add(_HeapEntry(start, 0));
    String? goal;
    var visited = 0;
    while (heap.isNotEmpty && visited < 220000) {
      final entry = heap.removeFirst();
      if (entry.score > (best[entry.key] ?? double.infinity)) continue;
      visited++;
      final split = entry.key.indexOf(sep);
      final station = entry.key.substring(0, split);
      final previousService = entry.key.substring(split + sep.length);
      if (station == to) {
        goal = entry.key;
        break;
      }
      for (final edge in edges[station] ?? const <TransitLink>[]) {
        final nextRide = edge.service == 'walk' ? previousService : edge.ride;
        final transferCost =
            previousService.isNotEmpty && previousService != nextRide
            ? 440.0
            : 0.0;
        final next = edge.to + sep + nextRide;
        final score = entry.score + edge.score + transferCost;
        if (score < (best[next] ?? double.infinity)) {
          best[next] = score;
          parent[next] = entry.key;
          via[next] = edge;
          heap.add(_HeapEntry(next, score));
        }
      }
    }
    if (goal == null) return null;
    final links = <TransitLink>[];
    final locations = <TransitStop>[stops[to]!];
    var at = goal;
    while (at != start) {
      final link = via[at], previous = parent[at];
      if (link == null || previous == null) return null;
      links.add(link);
      locations.add(stops[previous.substring(0, previous.indexOf(sep))]!);
      at = previous;
    }
    final routeStops = locations.reversed.toList();
    final orderedLinks = links.reversed.toList();
    final legs = <TransitLeg>[];
    var walk = 0.0, total = 0.0, changes = 0, i = 0;
    String? lastRide;
    while (i < orderedLinks.length) {
      final service = orderedLinks[i].service;
      final ride = orderedLinks[i].ride;
      final legStops = <TransitStop>[routeStops[i]];
      var meters = 0.0;
      while (i < orderedLinks.length && orderedLinks[i].ride == ride) {
        meters += orderedLinks[i].meters;
        total += orderedLinks[i].meters;
        legStops.add(routeStops[i + 1]);
        i++;
      }
      if (service == 'walk') {
        walk += meters;
      } else {
        if (lastRide != null && lastRide != ride) changes++;
        lastRide = ride;
      }
      legs.add(
        TransitLeg(service, legStops, meters, direction: rideDirections[ride]),
      );
    }
    return TransitPlan(routeStops, legs, changes, walk, total);
  }
}

String normalizeTransitSearch(String text) =>
    asciiDigits(text)
        .toLowerCase()
        .replaceAll('ي', 'ی')
        .replaceAll('ى', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll(RegExp(r'[ً-ٰٟ]'), '')
        .replaceAll(RegExp(r'[\s‌]+'), ' ')
        .trim();
