import 'package:flutter_test/flutter_test.dart';
import 'package:tehran_transit/persian_digits.dart';
import 'package:tehran_transit/offline_map.dart';

void main() {
  test('displays metro and bus numbers in Persian', () {
    expect(persianDigits('BRT 101 / 7'), 'BRT ۱۰۱ / ۷');
    expect(persianDigits(905), '۹۰۵');
    expect(persianDigits('شریعتی'), 'شریعتی');
  });

  test('search accepts Persian and Arabic-Indic digits', () {
    expect(asciiDigits('خط ۱۰۱'), 'خط 101');
    expect(asciiDigits('خط ١٠١'), 'خط 101');
    expect(asciiDigits('خط 101'), 'خط 101');
  });

  test('offline map manifest requires HTTPS, SHA256 and raster MBTiles', () {
    const hash =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final release = MapRelease.parse({
      'edition': '2026-Q4',
      'url': 'https://maps.example.com/tehran.mbtiles',
      'sha256': hash,
      'format': 'raster_mbtiles',
      'bytes': 125000,
    });
    expect(release.edition, '2026-Q4');
    expect(release.bytes, 125000);
    expect(
      () => MapRelease.parse({
        'edition': '2026-Q4',
        'url': 'http://unsafe.example/tehran.mbtiles',
        'sha256': hash,
        'format': 'raster_mbtiles',
      }),
      throwsFormatException,
    );
    expect(
      () => MapRelease.parse({
        'edition': '2026-Q4',
        'url': 'https://maps.example.com/tehran.mbtiles',
        'sha256': hash,
        'format': 'vector_pmtiles',
      }),
      throwsFormatException,
    );
  });
}
