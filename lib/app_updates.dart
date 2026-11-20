import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Only publicly published APK releases are eligible. The map MBTiles release
/// must never be confused with an application update.
class RahaAppUpdate {
  final String version;
  final Uri downloadUrl;
  final String title;
  const RahaAppUpdate(this.version, this.downloadUrl, this.title);

  static int compareVersions(String a, String b) {
    List<int> parts(String version) {
      final fields = version.split('+');
      final semver = fields.first.split('.');
      return [
        for (var i = 0; i < 3; i++)
          i < semver.length ? int.tryParse(semver[i]) ?? 0 : 0,
        fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0,
      ];
    }

    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return 0;
  }

  static Future<RahaAppUpdate?> check() async {
    final info = await PackageInfo.fromPlatform();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.https(
        'api.github.com',
        '/repos/Hosseinronaghi/Tehran-Transit/releases',
        {'per_page': '20'},
      );
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'RahaTehran-Android');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await req.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok)
        throw const HttpException('Release listing unavailable');
      var size = 0;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        size += chunk.length;
        if (size > 250000) return null;
        bytes.addAll(chunk);
      }
      final releases = jsonDecode(utf8.decode(bytes));
      if (releases is! List) return null;
      RahaAppUpdate? newest;
      for (final release in releases) {
        if (release is! Map ||
            release['draft'] == true ||
            release['prerelease'] == true)
          continue;
        final versionMatch = RegExp(r'^v?(\d+\.\d+\.\d+(?:\+\d+)?)$')
            .firstMatch(release['tag_name']?.toString() ?? '');
        if (versionMatch == null) continue;
        final version = versionMatch.group(1)!;
        if (compareVersions(version, '${info.version}+${info.buildNumber}') <=
            0)
          continue;
        final assets = release['assets'];
        if (assets is! List) continue;
        for (final asset in assets) {
          if (asset is! Map) continue;
          final name = asset['name']?.toString().toLowerCase() ?? '';
          final url = Uri.tryParse(
            asset['browser_download_url']?.toString() ?? '',
          );
          if (!name.endsWith('.apk') ||
              url == null ||
              url.scheme != 'https' ||
              url.host != 'github.com' ||
              !url.path.startsWith(
                '/Hosseinronaghi/Tehran-Transit/releases/download/',
              ))
            continue;
          if (newest == null || compareVersions(version, newest.version) > 0) {
            newest = RahaAppUpdate(
              version,
              url,
              release['name']?.toString() ?? 'رها تهران',
            );
          }
        }
      }
      return newest;
    } finally {
      client.close(force: true);
    }
  }
}
