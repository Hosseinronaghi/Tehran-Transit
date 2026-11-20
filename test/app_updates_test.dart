import 'package:flutter_test/flutter_test.dart';
import 'package:tehran_transit/app_updates.dart';

void main() {
  test('version comparison includes the Android build number', () {
    expect(RahaAppUpdate.compareVersions('0.6.10', '0.6.9'), greaterThan(0));
    expect(
      RahaAppUpdate.compareVersions('0.6.3+10', '0.6.3+9'),
      greaterThan(0),
    );
    expect(RahaAppUpdate.compareVersions('0.6.3+10', '0.6.3+10'), 0);
    expect(RahaAppUpdate.compareVersions('0.6.2+500', '0.6.3+1'), lessThan(0));
  });
}
