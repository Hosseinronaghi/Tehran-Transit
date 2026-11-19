import 'package:flutter_test/flutter_test.dart';
import 'package:tehran_transit/app_updates.dart';

void main() {
  test('version comparison is numeric rather than lexicographical', () {
    expect(RahaAppUpdate.compareVersions('0.6.10', '0.6.9'), greaterThan(0));
    expect(RahaAppUpdate.compareVersions('0.6.3', '0.6.2'), greaterThan(0));
    expect(RahaAppUpdate.compareVersions('0.6.3', '0.6.3'), 0);
    expect(RahaAppUpdate.compareVersions('0.6.2', '0.6.3'), lessThan(0));
  });

  test('update reminder cadence', () {
    expect(RahaAppUpdate.interval('weekly')!.inDays, 7);
    expect(RahaAppUpdate.interval('monthly')!.inDays, 30);
    expect(RahaAppUpdate.interval('quarterly')!.inDays, 90);
    expect(RahaAppUpdate.interval('off'), isNull);
  });
}
