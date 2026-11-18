import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Manifest is published independently of the APK for quarterly map updates.
/// Never fetch map tiles in bulk from the public OSM tile servers.
const mapManifestUrl = String.fromEnvironment('RAHA_MAP_MANIFEST_URL');

class MapRelease {
  final String edition, url, sha256;
  final int? bytes;
  const MapRelease(this.edition, this.url, this.sha256, this.bytes);
  factory MapRelease.parse(Map<String, dynamic> data) {
    final edition = data['edition']?.toString() ?? '';
    final url = data['url']?.toString() ?? '';
    final sha = data['sha256']?.toString() ?? '';
    final format = data['format']?.toString();
    if (edition.length < 4 || edition.length > 40 ||
        !url.startsWith('https://') ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha) ||
        format != 'raster_mbtiles') {
      throw const FormatException('اطلاعات بسته نقشه معتبر نیست.');
    }
    return MapRelease(edition, url, sha,
        data['bytes'] is int ? data['bytes'] as int : null);
  }
}

class OfflineMapController extends ChangeNotifier {
  MbTilesTileProvider? provider;
  HttpClient? _client;
  bool busy = false;
  bool checking = false;
  bool cancelled = false;
  MapRelease? availableRelease;
  double? progress;
  String? error;
  String? installedEdition;
  DateTime? installedAt;
  int installedBytes = 0;

  bool get installed => provider != null;
  bool get canCheck => mapManifestUrl.startsWith('https://');
  bool get downloadable => availableRelease != null;
  bool get updateAvailable =>
      installed && downloadable && installedEdition != availableRelease!.edition;

  /// Network access only after explicit user request. No background download.
  Future<void> checkForUpdates() async {
    if (!canCheck || busy || checking) return;
    checking = true;
    error = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(mapManifestUrl));
      final response = await req.close().timeout(const Duration(seconds: 25));
      if (response.statusCode != 200 || response.contentLength > 65536) {
        throw const HttpException('فهرست انتشار نقشه در دسترس نیست.');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final bytes in response.timeout(const Duration(seconds: 25))) {
        buffer.add(bytes);
        if (buffer.length > 65536) {
          throw const FormatException('فهرست نقشه بیش از حد بزرگ است.');
        }
      }
      final manifest = jsonDecode(utf8.decode(buffer.takeBytes()))
          as Map<String, dynamic>;
      availableRelease = MapRelease.parse(manifest);
    } catch (e) {
      error = 'بررسی نسخه جدید ممکن نشد: ' + e.toString();
    } finally {
      client.close(force: true);
      checking = false;
      notifyListeners();
    }
  }

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'maps'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'tehran.mbtiles'));
  }

  Future<void> _check(File file) async {
    if (!await file.exists() || await file.length() < 100 * 1024) {
      throw const FormatException('فایل نقشه ناقص است.');
    }
    final db = await openDatabase(file.path, readOnly: true, singleInstance: false);
    try {
      final fmt = await db.rawQuery(
          "SELECT value FROM metadata WHERE name='format' LIMIT 1");
      if (fmt.isEmpty ||
          !['png', 'jpg', 'jpeg', 'webp']
              .contains(fmt.first['value']?.toString().toLowerCase())) {
        throw const FormatException('فقط بسته رستری MBTiles پشتیبانی می‌شود.');
      }
      final firstTile = await db.rawQuery('SELECT zoom_level FROM tiles LIMIT 1');
      if (firstTile.isEmpty) {
        throw const FormatException('بسته نقشه کاشی ندارد.');
      }
    } finally {
      await db.close();
    }
  }

  Future<void> initialize() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        await _check(file);
        provider = MbTilesTileProvider.fromPath(path: file.path);
        installedBytes = await file.length();
        installedAt = await file.lastModified();
        final version = File(file.path + '.edition');
        installedEdition =
            await version.exists() ? await version.readAsString() : 'ناشناس';
      }
    } catch (e) {
      error = 'نقشه ذخیره‌شده قابل خواندن نیست: ' + e.toString();
    }
    notifyListeners();
  }

  /// An explicit user gesture triggers a download. Validates HTTPS, SHA256,
  /// SQLite and raster tile format; keeps incomplete files out of the app.
  Future<void> download() async {
    if (busy || !downloadable) return;
    final release = availableRelease!;
    busy = true;
    cancelled = false;
    error = null;
    progress = null;
    notifyListeners();
    File? partial;
    try {
      final destination = await _file();
      partial = File(destination.path + '.part');
      if (await partial.exists()) await partial.delete();
      _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final request = await _client!.getUrl(Uri.parse(release.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('پاسخ نامعتبر سرور: ' +
            response.statusCode.toString());
      }
      if (response.redirects.any((r) => r.location.scheme != 'https')) {
        throw const HttpException('تغییر مسیر دانلود امن نیست.');
      }
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (cancelled) throw const HttpException('دانلود لغو شد.');
          received += chunk.length;
          if (received > 1500 * 1024 * 1024) {
            throw const HttpException('حجم بسته بیش از سقف مجاز است.');
          }
          sink.add(chunk);
          if (response.contentLength > 0) {
            progress = received / response.contentLength;
            notifyListeners();
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      final digest = await sha256.bind(partial.openRead()).first;
      if (digest.toString().toLowerCase() != release.sha256.toLowerCase()) {
        throw const FormatException('اثر انگشت SHA256 نقشه مطابقت ندارد.');
      }
      await _check(partial);
      final oldProvider = provider;
      provider = null;
      oldProvider?.dispose();
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      final editionFile = File(destination.path + '.edition');
      await editionFile.writeAsString(release.edition, flush: true);
      provider = MbTilesTileProvider.fromPath(path: destination.path);
      installedBytes = await destination.length();
      installedAt = await destination.lastModified();
      installedEdition = release.edition;
    } catch (e) {
      error = cancelled
          ? 'دانلود لغو شد.'
          : 'دریافت نقشه ممکن نشد: ' + e.toString();
      if (provider == null) {
        try {
          final old = await _file();
          if (await old.exists()) {
            provider = MbTilesTileProvider.fromPath(path: old.path);
          }
        } catch (_) {}
      }
    } finally {
      if (partial != null && await partial.exists()) {
        await partial.delete();
      }
      _client?.close(force: true);
      _client = null;
      busy = false;
      progress = null;
      notifyListeners();
    }
  }

  void cancelDownload() {
    cancelled = true;
    _client?.close(force: true);
  }

  Future<void> remove() async {
    if (busy) return;
    provider?.dispose();
    provider = null;
    final file = await _file();
    if (await file.exists()) await file.delete();
    final version = File(file.path + '.edition');
    if (await version.exists()) await version.delete();
    installedEdition = null;
    installedAt = null;
    installedBytes = 0;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close(force: true);
    provider?.dispose();
    super.dispose();
  }
}
