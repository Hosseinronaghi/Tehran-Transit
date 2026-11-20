import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

const mapManifestUrl = String.fromEnvironment(
  'RAHA_MAP_MANIFEST_URL',
  defaultValue: 'https://github.com/Hosseinronaghi/Tehran-Transit/releases/download/tehran-offline-maps/manifest.json',
);
const _buildMirror = String.fromEnvironment('RAHA_MAP_MIRROR_URL');
const _releaseApi =
    'https://api.github.com/repos/Hosseinronaghi/Tehran-Transit/releases';
const _maxBytes = 1500 * 1024 * 1024;
const _idleTimeout = Duration(seconds: 12);
const _networkError =
    'اتصال به منبع نقشه برقرار نشد. دوباره تلاش کنید یا از فایل نقشه استفاده کنید.';

Uri? mapHttpsUri(String address) {
  final uri = Uri.tryParse(address.trim());
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment
      ? uri
      : null;
}

class MapRelease {
  final String edition, url, sha256;
  final int? bytes;
  final int minZoom, maxZoom;
  final List<Uri> mirrors;
  const MapRelease(
    this.edition,
    this.url,
    this.sha256,
    this.bytes, {
    this.minZoom = 9,
    this.maxZoom = 15,
    this.mirrors = const [],
  });

  static const bundled = MapRelease(
    '2026-Q4-r3',
    'https://github.com/Hosseinronaghi/Tehran-Transit/releases/download/tehran-offline-maps/tehran-2026-Q4-r3.mbtiles',
    '6b8a95275c8db04d2223bd0a920f664cb12ba99f82bf76bcb4ebf3a765b13fae',
    37007360,
  );

  factory MapRelease.parse(
    Map<String, dynamic> data, {
    List<Uri> alternatives = const [],
  }) {
    final edition = data['edition']?.toString() ?? '';
    final url = data['url']?.toString() ?? '';
    final sha = data['sha256']?.toString().toLowerCase() ?? '';
    final bytes = data['bytes'];
    final min = data['minzoom'] ?? 9;
    final max = data['maxzoom'] ?? 15;
    if (edition.length < 4 ||
        edition.length > 40 ||
        mapHttpsUri(url) == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
        data['format'] != 'raster_mbtiles' ||
        (bytes != null &&
            (bytes is! int || bytes < 102400 || bytes > _maxBytes)) ||
        min is! int ||
        max is! int ||
        min < 0 ||
        max < min ||
        max > 22) {
      throw const FormatException('اطلاعات بستهٔ نقشه معتبر نیست.');
    }
    return MapRelease(
      edition,
      url,
      sha,
      bytes as int?,
      minZoom: min,
      maxZoom: max,
      mirrors: [
        ...alternatives,
        if (data['mirrors'] case final List links)
          for (final link in links)
            if (mapHttpsUri(link.toString()) case final Uri uri) uri,
        if (sha == bundled.sha256) Uri.parse('$_releaseApi/assets/765279045'),
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'edition': edition,
    'url': url,
    'sha256': sha256,
    'format': 'raster_mbtiles',
    'bytes': bytes,
    'minzoom': minZoom,
    'maxzoom': maxZoom,
    'mirrors': mirrors.map((uri) => uri.toString()).toList(),
  };

  bool olderThan(String? other) {
    Iterable<int>? fields(String text) {
      final match = RegExp(r'^(\d{4})-Q([1-4])-r(\d+)$').firstMatch(text);
      return match == null
          ? null
          : [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
    }

    final a = fields(edition)?.toList(), b = fields(other ?? '')?.toList();
    if (a == null || b == null) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
  }
}

Duration? mapCheckInterval(String cadence) => switch (cadence) {
  'weekly' => const Duration(days: 7),
  'monthly' => const Duration(days: 30),
  'quarterly' => const Duration(days: 90),
  _ => null,
};

class OfflineMapController extends ChangeNotifier {
  OfflineMapController({this.bundledRelease = MapRelease.bundled});

  final MapRelease bundledRelease;
  static const _storage = MethodChannel(
    'org.tehrantransit.tehran_transit/storage',
  );
  (double, double, double, double) bounds = (50.86, 35.43, 51.78, 35.95);

  /// The TileLayer receives its own provider for each mount and disposes it.
  File? installedFile;
  int minZoom = 9, maxZoom = 15;
  bool preferOffline = true;
  String cadence = 'quarterly';
  String mirror = '';
  bool ready = false, busy = false, checking = false;
  bool _cancelled = false, _disposed = false;
  HttpClient? _client, _checkClient;
  Future<void>? _initialization;
  DateTime? _lastAttempt;
  MapRelease? availableRelease;
  MapRelease? _installedRelease;
  double? progress;
  String? error, checkError;
  String? installedEdition;
  int installedBytes = 0;

  bool get installed => installedFile != null;
  bool get updateAvailable =>
      installed &&
      availableRelease != null &&
      availableRelease!.edition != installedEdition &&
      !availableRelease!.olderThan(installedEdition);
  MapRelease get downloadRelease => availableRelease ?? bundledRelease;

  MbTilesTileProvider openProvider() =>
      MbTilesTileProvider.fromPath(path: installedFile!.path);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'maps')).create(recursive: true);
  }

  File _pack(Directory dir, MapRelease release) =>
      File(p.join(dir.path, '${release.sha256}.mbtiles'));
  File _pointer(Directory dir) => File(p.join(dir.path, 'active.json'));

  Future<(double, double, double, double)?> _check(File file) async {
    if (!await file.exists() || await file.length() < 102400) {
      throw const FormatException('فایل نقشه ناقص است.');
    }
    final db = await openDatabase(
      file.path,
      readOnly: true,
      singleInstance: false,
    );
    try {
      final fmt = await db.rawQuery(
        "SELECT value FROM metadata WHERE name='format' LIMIT 1",
      );
      if (fmt.isEmpty ||
          ![
            'png',
            'jpg',
            'jpeg',
            'webp',
          ].contains(fmt.first['value'].toString().toLowerCase()) ||
          (await db.rawQuery('SELECT tile_data FROM tiles LIMIT 1')).isEmpty) {
        throw const FormatException('فایل MBTiles رستری قابل خواندن نیست.');
      }
      final records = await db.rawQuery(
        "SELECT value FROM metadata WHERE name='bounds' LIMIT 1",
      );
      if (records.isEmpty) return null;
      final parts = records.first['value']
          .toString()
          .split(',')
          .map(double.tryParse)
          .toList();
      if (parts.length != 4 ||
          parts.any((v) => v == null || !v.isFinite) ||
          parts[0]! >= parts[2]! ||
          parts[1]! >= parts[3]!)
        return null;
      return (parts[0]!, parts[1]!, parts[2]!, parts[3]!);
    } finally {
      await db.close();
    }
  }

  Future<void> _setInstalled(
    File file,
    String edition,
    MapRelease? release,
    (double, double, double, double)? packBounds,
  ) async {
    installedBytes = await file.length();
    installedFile = file;
    installedEdition = edition;
    _installedRelease = release;
    minZoom = release?.minZoom ?? 9;
    maxZoom = release?.maxZoom ?? 15;
    bounds = packBounds ?? (50.86, 35.43, 51.78, 35.95);
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      cadence =
          prefs.getString('raha_map_cadence') ??
          ((prefs.getBool('raha_quarterly_map_reminder') ?? true)
              ? 'quarterly'
              : 'off');
      mirror = prefs.getString('raha_map_mirror') ?? '';
      preferOffline = prefs.getBool('raha_prefer_offline_map') ?? true;
      final cached = prefs.getString('raha_map_manifest');
      if (cached != null) {
        try {
          availableRelease = MapRelease.parse(
            jsonDecode(cached) as Map<String, dynamic>,
          );
        } catch (_) {
          await prefs.remove('raha_map_manifest');
        }
      }
      final dir = await _directory();
      final pointer = _pointer(dir);
      final retained = <String>{};
      if (await pointer.exists()) {
        try {
          final records = jsonDecode(await pointer.readAsString()) as List;
          for (final record in records) {
            try {
              final release = MapRelease.parse(
                Map<String, dynamic>.from(record as Map),
              );
              final file = _pack(dir, release);
              retained.add(file.path);
              if (!installed) {
                final packBounds = await _check(file);
                await _setInstalled(file, release.edition, release, packBounds);
              }
            } catch (_) {
              /* Try the previous validated package. */
            }
          }
        } catch (_) {
          /* Try files installed by earlier releases. */
        }
      }
      if (!installed) {
        for (final name in ['tehran.mbtiles', 'tehran.mbtiles.previous']) {
          final file = File(p.join(dir.path, name));
          if (!await file.exists()) continue;
          try {
            final packBounds = await _check(file);
            final version = File(p.join(dir.path, 'tehran.mbtiles.edition'));
            final edition = name == 'tehran.mbtiles' && await version.exists()
                ? (await version.readAsString()).trim()
                : 'ناشناس';
            await _setInstalled(file, edition, null, packBounds);
            break;
          } catch (_) {
            error = 'نقشهٔ ذخیره‌شده قابل خواندن نیست.';
          }
        }
      }
      if (_installedRelease != null) {
        await for (final file in dir.list()) {
          if (file is File &&
              p.basename(file.path).endsWith('.mbtiles') &&
              !retained.contains(file.path)) {
            try {
              await file.delete();
            } on FileSystemException {
              /* Retry on a later launch. */
            }
          }
        }
      }
    } catch (_) {
      error = 'خواندن تنظیمات یا فایل نقشه ممکن نشد.';
    } finally {
      ready = true;
      _changed();
    }
  }

  Future<void> setCadence(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('raha_map_cadence', value);
    cadence = value;
    _lastAttempt = null;
    _changed();
    if (value != 'off') await checkWhenDue();
  }

  Future<void> setMirror(String value) async {
    if (value.trim().isNotEmpty && mapHttpsUri(value) == null) {
      throw const FormatException('نشانی HTTPS فهرست نقشه معتبر نیست.');
    }
    final prefs = await SharedPreferences.getInstance();
    mirror = value.trim();
    await prefs.setString('raha_map_mirror', mirror);
    _changed();
  }

  Future<void> setPreferOffline(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('raha_prefer_offline_map', value);
    preferOffline = value;
    _changed();
  }

  Future<void> checkWhenDue() async {
    await initialize();
    final interval = mapCheckInterval(cadence);
    if (interval == null || _disposed) return;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final last = prefs.getInt('raha_last_map_check');
    if (last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)).inDays >= 0 &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)) < interval)
      return;
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!).abs() < const Duration(minutes: 15))
      return;
    await checkForUpdates(automatic: true);
  }

  HttpClient _newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..autoUncompress = false;

  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri, {
    int offset = 0,
    bool json = false,
  }) async {
    for (var i = 0; i < 5; i++) {
      final req = await client.getUrl(uri).timeout(_idleTimeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'RahaTehran-Android');
      req.headers.set(
        HttpHeaders.acceptHeader,
        json ? 'application/json' : 'application/octet-stream',
      );
      if (offset > 0)
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await req.close().timeout(_idleTimeout);
      if (![301, 302, 303, 307, 308].contains(response.statusCode))
        return response;
      final redirect = response.headers.value(HttpHeaders.locationHeader);
      final next = redirect == null
          ? null
          : mapHttpsUri(uri.resolve(redirect).toString());
      if (next == null)
        throw const HttpException('نشانی انتقال نقشه معتبر نیست.');
      await response.drain<void>().timeout(_idleTimeout);
      uri = next;
    }
    throw const HttpException('مسیر دریافت نقشه بیش از حد تغییر کرد.');
  }

  Future<Map<String, dynamic>> _json(
    HttpClient client,
    Uri uri, {
    bool json = true,
  }) async {
    final response = await _open(client, uri, json: json);
    if (response.statusCode != 200)
      throw const HttpException('فهرست در دسترس نیست.');
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_idleTimeout)) {
      if (buffer.length + chunk.length > 256 * 1024)
        throw const FormatException();
      buffer.add(chunk);
    }
    return jsonDecode(utf8.decode(buffer.takeBytes())) as Map<String, dynamic>;
  }

  Future<MapRelease> _githubApiRelease(HttpClient client) async {
    final metadata = await _json(
      client,
      Uri.parse('$_releaseApi/tags/tehran-offline-maps'),
    );
    final assets = (metadata['assets'] as List).whereType<Map>();
    final manifest = assets.firstWhere(
      (asset) => asset['name'] == 'manifest.json',
    );
    final manifestUrl = Uri.parse('$_releaseApi/assets/${manifest['id']}');
    final data = await _json(client, manifestUrl, json: false);
    final primary = mapHttpsUri(data['url']?.toString() ?? '');
    return MapRelease.parse(
      data,
      alternatives: [
        for (final asset in assets)
          if (primary != null &&
              asset['name'] == primary.pathSegments.last &&
              asset['id'] is int)
            Uri.parse('$_releaseApi/assets/${asset['id']}'),
      ],
    );
  }

  Future<void> checkForUpdates({bool automatic = false}) async {
    await initialize();
    if (_disposed || busy || checking) return;
    checking = true;
    _lastAttempt = DateTime.now();
    if (!automatic) checkError = null;
    _changed();
    final sources = <Future<MapRelease> Function(HttpClient)>[
      for (final address in {mirror, _buildMirror, mapManifestUrl})
        if (mapHttpsUri(address) case final Uri uri)
          (client) async => MapRelease.parse(await _json(client, uri)),
      _githubApiRelease,
    ];
    try {
      for (final source in sources) {
        if (_disposed) return;
        _checkClient = _newClient();
        try {
          final release = await source(_checkClient!)
              .timeout(const Duration(seconds: 25));
          if (_disposed) return;
          if (!release.olderThan(installedEdition) &&
              !release.olderThan(availableRelease?.edition)) {
            availableRelease = release;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(
              'raha_map_manifest',
              jsonEncode(release.toJson()),
            );
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(
            'raha_last_map_check',
            DateTime.now().millisecondsSinceEpoch,
          );
          checkError = null;
          return;
        } catch (_) {
          // The next configured source can be reached on a different network.
        } finally {
          _checkClient?.close(force: true);
          _checkClient = null;
        }
      }
      if (!automatic) checkError = _networkError;
    } finally {
      checking = false;
      _changed();
    }
  }

  void _assertActive() {
    if (_cancelled || _disposed) throw const _Cancelled();
  }

  Future<void> _activate(
    Directory dir,
    File candidate,
    MapRelease release,
  ) async {
    _assertActive();
    final length = await candidate.length();
    if (release.bytes != null && length != release.bytes)
      throw const FormatException('اندازهٔ بسته مطابقت ندارد.');
    final hash = await sha256.bind(candidate.openRead()).first;
    if (hash.toString() != release.sha256)
      throw const FormatException('اثر انگشت SHA-256 بسته مطابقت ندارد.');
    final packBounds = await _check(candidate);
    _assertActive();
    final file = _pack(dir, release);
    final previous = _installedRelease;
    // The old pointer is intact until the new, validated package is in place.
    await candidate.rename(file.path);
    final pending = File(p.join(dir.path, 'active.new'));
    await pending.writeAsString(
      jsonEncode([
        release.toJson(),
        if (previous != null && previous.sha256 != release.sha256)
          previous.toJson(),
      ]),
      flush: true,
    );
    _assertActive();
    await pending.rename(_pointer(dir).path);
    await _setInstalled(file, release.edition, release, packBounds);
    // The old map can still be in use by a mounted TileLayer. Files are cleaned
    // when the user removes the map, or on a later cold start.
  }

  Future<void> _writeChunks(
    File file,
    Stream<List<int>> chunks,
    int offset,
    int? total,
  ) async {
    final sink = file.openWrite(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    var received = offset;
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await sink.addStream(
        chunks.timeout(_idleTimeout).map((chunk) {
          _assertActive();
          received += chunk.length;
          if (received > _maxBytes || (total != null && received > total)) {
            throw const FormatException(
              'اندازهٔ بسته با فهرست انتشار هم‌خوانی ندارد.',
            );
          }
          final now = DateTime.now();
          if (total != null &&
              now.difference(lastUpdate).inMilliseconds >= 125) {
            progress = received / total;
            lastUpdate = now;
            _changed();
          }
          return chunk;
        }),
      );
    } finally {
      await sink.close();
    }
  }

  Future<void> _requireSpace(int? bytes) async {
    if (!Platform.isAndroid || bytes == null || bytes <= 0) return;
    final available = await _storage.invokeMethod<int>('availableBytes');
    if (available != null && available < bytes + 1024 * 1024) {
      throw const FileSystemException('Insufficient available space');
    }
  }

  Future<void> download(MapRelease release) async {
    await _run((dir) async {
      final partial = File(p.join(dir.path, '${release.sha256}.part'));
      var invalid = false;
      for (final uri in {
        ...release.mirrors,
        Uri.parse(release.url),
        if (release.sha256 == MapRelease.bundled.sha256)
          Uri.parse('$_releaseApi/assets/765279045'),
      }) {
        _assertActive();
        _client = _newClient();
        try {
          var offset = await partial.exists() ? await partial.length() : 0;
          if (release.bytes != null && offset > release.bytes!) {
            await partial.delete();
            offset = 0;
          }
          if (offset == 0 || offset != release.bytes) {
            await _requireSpace(
              release.bytes == null ? null : release.bytes! - offset,
            );
            var response = await _open(_client!, uri, offset: offset);
            if (response.statusCode == 416 && offset > 0) {
              await response.drain<void>().timeout(_idleTimeout);
              response = await _open(_client!, uri);
              offset = 0;
            }
            if (response.statusCode == HttpStatus.ok) {
              // Space already occupied by the partial can be reused.
              offset = 0;
            } else if (response.statusCode != HttpStatus.partialContent ||
                offset == 0 ||
                !validMapContentRange(
                  response.headers.value('content-range'),
                  offset,
                  release.bytes,
                )) {
              throw const HttpException('پاسخ دریافت نقشه معتبر نیست.');
            }
            if (response.headers.contentType?.mimeType == 'application/json') {
              throw const HttpException(
                'سرور به جای فایل نقشه، اطلاعات انتشار را فرستاد.',
              );
            }
            await _writeChunks(partial, response, offset, release.bytes);
          }
          if (release.bytes != null &&
              await partial.length() < release.bytes!) {
            throw const HttpException('فایل نقشه کامل دریافت نشد.');
          }
          await _activate(dir, partial, release);
          return;
        } on FormatException {
          invalid = true;
          if (await partial.exists()) await partial.delete();
        } on SocketException {
          _assertActive();
        } on TimeoutException {
          _assertActive();
        } on HttpException {
          _assertActive();
        } finally {
          _client?.close(force: true);
          _client = null;
        }
      }
      if (invalid)
        throw const FormatException(
          'فایل دریافت‌شده با بستهٔ معتبر نقشه مطابقت ندارد.',
        );
      throw const HttpException(_networkError);
    });
  }

  Future<void> importMap(Stream<List<int>> stream) async {
    await _run((dir) async {
      final temp = File(p.join(dir.path, 'import.part'));
      try {
        await _writeChunks(temp, stream, 0, null);
        final digest = (await sha256.bind(temp.openRead()).first).toString();
        final trusted = [downloadRelease, bundledRelease].where(
          (release) =>
              release.sha256 == digest && !release.olderThan(installedEdition),
        );
        if (trusted.isEmpty)
          throw const FormatException('فایل با فهرست معتبر نقشه مطابقت ندارد.');
        await _activate(dir, temp, trusted.first);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    });
  }

  Future<void> _run(Future<void> Function(Directory dir) operation) async {
    await initialize();
    if (_disposed || busy) return;
    busy = true;
    _cancelled = false;
    progress = null;
    error = null;
    _changed();
    try {
      await operation(await _directory());
    } on FormatException catch (e) {
      error = e.message;
    } on HttpException {
      error = _cancelled
          ? 'دریافت لغو شد. بخش دریافت‌شده برای تلاش بعدی نگه داشته شد.'
          : _networkError;
    } on _Cancelled {
      error =
          'عملیات نقشه لغو شد. دانلود نیمه‌تمام در تلاش بعدی قابل ادامه است.';
    } on FileSystemException {
      error = 'ذخیرهٔ نقشه ممکن نشد. فضای آزاد دستگاه را بررسی کنید.';
    } catch (_) {
      error = _cancelled
          ? 'عملیات نقشه لغو شد.'
          : 'نصب نقشه ممکن نشد. دوباره تلاش کنید.';
    } finally {
      busy = false;
      progress = null;
      _changed();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<void> remove() async {
    await _run((dir) async {
      final discarded = await dir.rename(
        '${dir.path}.removed-${DateTime.now().microsecondsSinceEpoch}',
      );
      installedFile = null;
      installedEdition = null;
      installedBytes = 0;
      _installedRelease = null;
      _changed();
      await discarded.delete(recursive: true);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _checkClient?.close(force: true);
    cancelDownload();
    super.dispose();
  }
}

bool validMapContentRange(String? header, int offset, int? expected) {
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(header ?? '');
  if (match == null) return false;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  return start == offset &&
      end != null &&
      total != null &&
      end >= offset &&
      end == total - 1 &&
      (expected == null || total == expected);
}

class _Cancelled implements Exception {
  const _Cancelled();
}
