import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Set only for a legally distributable, independently verified raster MBTiles
/// Tehran package. Never download tiles in bulk from tile.openstreetmap.org.
const mapPackageUrl = String.fromEnvironment('RAHA_MAP_URL');
const mapPackageSha = String.fromEnvironment('RAHA_MAP_SHA256');
const mapPackageEdition = String.fromEnvironment('RAHA_MAP_EDITION');

class OfflineMapController extends ChangeNotifier {
  MbTilesTileProvider? provider;
  HttpClient? _client;
  bool busy = false;
  bool cancelled = false;
  double? progress;
  String? error;
  String? installedEdition;
  DateTime? installedAt;
  int installedBytes = 0;

  bool get installed => provider != null;
  bool get downloadable => mapPackageUrl.startsWith('https://') &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(mapPackageSha) &&
      mapPackageEdition.isNotEmpty;
  bool get updateAvailable =>
      installed && downloadable && installedEdition != mapPackageEdition;

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
        provider = await MbTilesTileProvider.fromSource(file.path);
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
      final request = await _client!.getUrl(Uri.parse(mapPackageUrl));
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
      if (digest.toString().toLowerCase() != mapPackageSha.toLowerCase()) {
        throw const FormatException('اثر انگشت SHA256 نقشه مطابقت ندارد.');
      }
      await _check(partial);
      final oldProvider = provider;
      provider = null;
      oldProvider?.dispose();
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      final editionFile = File(destination.path + '.edition');
      await editionFile.writeAsString(mapPackageEdition, flush: true);
      provider = await MbTilesTileProvider.fromSource(destination.path);
      installedBytes = await destination.length();
      installedAt = await destination.lastModified();
      installedEdition = mapPackageEdition;
    } catch (e) {
      error = cancelled
          ? 'دانلود لغو شد.'
          : 'دریافت نقشه ممکن نشد: ' + e.toString();
      if (provider == null) {
        try {
          final old = await _file();
          if (await old.exists()) {
            provider = await MbTilesTileProvider.fromSource(old.path);
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
