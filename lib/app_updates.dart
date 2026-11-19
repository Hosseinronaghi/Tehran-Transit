import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only publicly published APK releases are eligible. The map MBTiles release
/// must never be confused with an application update.
class RahaAppUpdate {
  final String version;
  final Uri downloadUrl;
  final String title;
  const RahaAppUpdate(this.version, this.downloadUrl, this.title);

  static int compareVersions(String a, String b) {
    List<int> parts(String x) => x.split('+').first.split('.')
        .map((n) => int.tryParse(n) ?? 0).toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final lhs = i < x.length ? x[i] : 0;
      final rhs = i < y.length ? y[i] : 0;
      if (lhs != rhs) return lhs.compareTo(rhs);
    }
    return 0;
  }

  static Duration? interval(String value) {
    switch (value) {
      case 'weekly': return const Duration(days: 7);
      case 'monthly': return const Duration(days: 30);
      case 'quarterly': return const Duration(days: 90);
      default: return null;
    }
  }

  static Future<RahaAppUpdate?> check({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!force && !(prefs.getBool('raha_auto_update_check') ?? true)) return null;
    final frequency = prefs.getString('raha_update_frequency') ?? 'monthly';
    final period = interval(frequency);
    if (!force) {
      if (period == null) return null;
      final last = prefs.getInt('raha_last_app_update_check');
      if (last != null &&
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) < period) {
        return null;
      }
    }
    final info = await PackageInfo.fromPlatform();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.https('api.github.com',
          '/repos/Hosseinronaghi/Tehran-Transit/releases', {'per_page': '20'});
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'RahaTehran-Android');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await req.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != HttpStatus.ok) return null;
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
        if (release is! Map || release['draft'] == true ||
            release['prerelease'] == true) continue;
        final versionMatch = RegExp(r'\d+\.\d+\.\d+')
            .firstMatch(release['tag_name']?.toString() ?? '');
        if (versionMatch == null) continue;
        final version = versionMatch.group(0)!;
        if (compareVersions(version, info.version) <= 0) continue;
        final assets = release['assets'];
        if (assets is! List) continue;
        for (final asset in assets) {
          if (asset is! Map) continue;
          final name = asset['name']?.toString().toLowerCase() ?? '';
          final url = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
          if (!name.endsWith('.apk') || url == null ||
              url.scheme != 'https' || url.host != 'github.com') continue;
          if (newest == null || compareVersions(version, newest.version) > 0) {
            newest = RahaAppUpdate(version, url,
                release['name']?.toString() ?? 'رها تهران');
          }
        }
      }
      await prefs.setInt('raha_last_app_update_check',
          DateTime.now().millisecondsSinceEpoch);
      return newest;
    } finally {
      client.close(force: true);
    }
  }
}
