import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tehran_transit/route_engine.dart';

void main() {
  test('finds a multimodal route with a station-to-station walking transfer', () {
    final graph = TransitNetwork();
    graph.addStop(TransitStop('m1', 'مترو مبدأ', 'metro', const LatLng(35.7000, 51.4000)));
    graph.addStop(TransitStop('m2', 'مترو تبادل', 'metro', const LatLng(35.7000, 51.4100)));
    graph.addStop(TransitStop('b1', 'اتوبوس تبادل', 'bus', const LatLng(35.7001, 51.4101)));
    graph.addStop(TransitStop('b2', 'اتوبوس مقصد', 'bus', const LatLng(35.7010, 51.4200)));
    graph.addService(const TransitService('metro:1', 'metro', '1'));
    graph.addService(const TransitService('bus:12', 'bus', '12'));
    graph.addLink('m1', 'm2', 'metro:1', both: true);
    graph.addLink('b1', 'b2', 'bus:12');
    graph.addWalkingTransfers();

    final result = graph.plan('m1', 'b2');
    expect(result, isNotNull);
    expect(result!.stops.first.id, 'm1');
    expect(result.stops.last.id, 'b2');
    expect(result.walkingMeters, greaterThan(0));
    expect(result.legs.map((leg) => leg.service),
        containsAllInOrder(['metro:1', 'walk', 'bus:12']));
  });

  test('respects one-way directed bus links', () {
    final graph = TransitNetwork();
    graph.addStop(TransitStop('a', 'A', 'bus', const LatLng(35.700, 51.400)));
    graph.addStop(TransitStop('b', 'B', 'bus', const LatLng(35.700, 51.410)));
    graph.addLink('a', 'b', 'bus:20');
    expect(graph.plan('a', 'b'), isNotNull);
    expect(graph.plan('b', 'a'), isNull);
  });

  test('returns a zero-step route for identical stations', () {
    final graph = TransitNetwork();
    graph.addStop(TransitStop('a', 'A', 'metro', const LatLng(35.700, 51.400)));
    final result = graph.plan('a', 'a');
    expect(result, isNotNull);
    expect(result!.legs, isEmpty);
    expect(result.approximateMeters, 0);
  });
}
