import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updates.dart';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_map.dart';
import 'raha_colors.dart';
import 'persian_digits.dart';

class RahaSettingsPage extends StatefulWidget {
  final OfflineMapController offlineMap;
  final RahaColors colors;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<int> Function(String) importTimetable;
  const RahaSettingsPage({
    super.key,
    required this.offlineMap,
    required this.colors,
    required this.themeMode,
    required this.onThemeChanged,
    required this.importTimetable,
  });
  @override
  State<RahaSettingsPage> createState() => _RahaSettingsPageState();
}

class _RahaSettingsPageState extends State<RahaSettingsPage> {
  bool locationEnabled = true;
  bool followLocation = true;
  late ThemeMode selectedTheme;
  PackageInfo? packageInfo;
  bool checkingApp = false;
  @override
  void initState() {
    super.initState();
    selectedTheme = widget.themeMode;
    PackageInfo.fromPlatform()
        .then((value) {
          if (mounted) setState(() => packageInfo = value);
        })
        .catchError((Object error) {
          // Device metadata may be unavailable in preview/test environments.
        });
    widget.offlineMap.addListener(_refresh);
    widget.colors.addListener(_refresh);
    _readPrefs();
  }

  Future<void> _readPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted)
      setState(() {
        locationEnabled = prefs.getBool('raha_location_enabled') ?? true;
        followLocation = prefs.getBool('raha_follow_location') ?? true;
      });
  }

  Future<void> _checkAppUpdate() async {
    if (checkingApp) return;
    setState(() => checkingApp = true);
    try {
      final update = await RahaAppUpdate.check();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('نسخه جدید APK در انتشارهای معتبر پیدا نشد.'),
          ),
        );
      } else {
        final approved = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('نسخه جدید رها تهران'),
            content: Text(
              'نسخه ' + persianDigits(update.version) + ' منتشر شده است. دانلود و نصب فقط با انتخاب شما انجام می‌شود.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('بعداً'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('دریافت نسخه'),
              ),
            ],
          ),
        );
        if (approved == true)
          await launchUrl(
            update.downloadUrl,
            mode: LaunchMode.externalApplication,
          );
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('بررسی نسخه جدید فعلاً ممکن نیست.')),
        );
    } finally {
      if (mounted) setState(() => checkingApp = false);
    }
  }

  Future<void> _savePref(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) await prefs.setBool(key, value);
    if (value is String) await prefs.setString(key, value);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _deleteMap() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف نقشه آفلاین'),
        content: const Text(
          'نقشه خیابان‌های دانلودشده حذف می‌شود. اطلاعات ایستگاه‌ها '
          'و مسیریابی آفلاین همچنان باقی می‌ماند.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف نقشه'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.offlineMap.remove();
  }

  Widget _colorRow(String key) {
    final selected = widget.colors.forPart(key);
    final title = RahaColors.labels[key] ?? key;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              for (final swatch in RahaColors.choices)
                Tooltip(
                  message: 'انتخاب رنگ برای ' + title,
                  child: Semantics(
                    button: true,
                    selected: selected == swatch,
                    label: 'انتخاب رنگ برای ' + title,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => widget.colors.setColor(key, swatch),
                      child: Container(
                        width: 37,
                        height: 37,
                        decoration: BoxDecoration(
                          color: swatch,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected == swatch
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: selected == swatch
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _downloadMap() async {
    final offline = widget.offlineMap;
    if (offline.busy || !offline.ready) return;
    final release = offline.downloadRelease;
    if (offline.installed &&
        (release.edition == offline.installedEdition ||
            release.olderThan(offline.installedEdition))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'نسخهٔ قابل دریافت روی گوشی نصب است. برای دریافت نسخهٔ بعدی، انتشار نقشه را بررسی کنید.',
          ),
        ),
      );
      return;
    }
    final size = release.bytes == null
        ? 'حجم دقیق توسط ناشر اعلام نشده است.'
        : 'حجم تقریبی: ' +
              persianDigits(
                (release.bytes! / (1024 * 1024)).toStringAsFixed(1),
              ) +
              ' مگابایت';
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('دانلود نقشه تهران برای استفاده آفلاین'),
        content: Text(
          'نسخه ' +
              persianDigits(release.edition) +
              '\n' +
              size +
              '\nدانلود اختیاری است و فقط پس از تأیید شما شروع می‌شود.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('انصراف'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.download),
            label: const Text('شروع دانلود'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await offline.download(release);
  }

  Future<void> _importMap() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mbtiles'],
        withReadStream: true,
      );
      final stream = result?.files.single.readStream;
      if (mounted && stream != null) await widget.offlineMap.importMap(stream);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('باز کردن فایل نقشه ممکن نشد.')),
      );
    }
  }

  Future<void> _editMirror() async {
    var address = widget.offlineMap.mirror;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('نشانی فهرست جایگزین نقشه'),
        content: TextFormField(
          initialValue: address,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.url,
          onChanged: (text) => address = text,
          decoration: const InputDecoration(
            hintText: 'https://…/manifest.json',
            helperText: 'نشانی HTTPS یک ناشر مورد اعتماد',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, address),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    try {
      await widget.offlineMap.setMirror(value);
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _importTimetable() async {
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withReadStream: true,
      );
      if (selected == null || !mounted) return;
      final stream = selected.files.single.readStream;
      if (stream == null)
        throw const FormatException('فایل زمان‌بندی قابل خواندن نیست.');
      final buffer = BytesBuilder(copy: false);
      await for (final bytes in stream) {
        if (buffer.length + bytes.length > 8 * 1024 * 1024) {
          throw const FormatException('فایل زمان‌بندی بیش از حد بزرگ است.');
        }
        buffer.add(bytes);
      }
      if (!mounted) return;
      final count = await widget.importTimetable(
        utf8.decode(buffer.takeBytes()),
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${persianDigits(count)} ردیف جدید زمان‌بندی وارد شد.',
            ),
          ),
        );
    } on FormatException catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.source == null
                  ? error.message
                  : 'قالب فایل زمان‌بندی معتبر نیست.',
            ),
          ),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ورود زمان‌بندی ممکن نشد.')),
        );
    }
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
    child: Align(
      alignment: Alignment.centerRight,
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final offline = widget.offlineMap;
    final status = offline.installed
        ? 'نصب‌شده · ' +
              persianDigits(
                (offline.installedBytes / (1024 * 1024)).toStringAsFixed(1),
              ) +
              ' مگابایت · نسخه ' +
              persianDigits(offline.installedEdition)
        : 'نقشه خیابان‌های تهران هنوز دانلود نشده است.';
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تنظیمات رها تهران')),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _heading('ظاهر برنامه'),
            Card(
              child: Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.font_download_outlined),
                    title: Text('فونت برنامه'),
                    subtitle: Text('وزیر (Vazir)'),
                  ),
                  const ListTile(
                    leading: Icon(Icons.format_list_numbered_rtl),
                    title: Text('اعداد خطوط'),
                    subtitle: Text(
                      'نمایش فارسی؛ جست‌وجو با ارقام فارسی یا انگلیسی',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('حالت نمایش'),
                        const SizedBox(height: 9),
                        SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('خودکار'),
                              icon: Icon(Icons.brightness_auto_outlined),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('روشن'),
                              icon: Icon(Icons.light_mode_outlined),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('تاریک'),
                              icon: Icon(Icons.dark_mode_outlined),
                            ),
                          ],
                          selected: {selectedTheme},
                          onSelectionChanged: (s) {
                            setState(() => selectedTheme = s.first);
                            widget.onThemeChanged(s.first);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Card(
              child: ExpansionTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('شخصی‌سازی رنگ‌ها'),
                subtitle: const Text('برای نمایش گزینه‌های رنگ باز کنید'),
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final key in RahaColors.labels.keys) _colorRow(key),
                      SwitchListTile.adaptive(
                        title: const Text('رنگ اصلی هر خط مترو'),
                        subtitle: const Text(
                          'در صورت فعال‌بودن، رنگ ثبت‌شده منبع داده برای خطوط '
                          'استفاده می‌شود؛ در غیر این صورت رنگ انتخابی شما.',
                        ),
                        value: widget.colors.useSourceLineColors,
                        onChanged: (v) =>
                            widget.colors.setUseSourceLineColors(v),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => widget.colors.reset(),
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('بازنشانی رنگ‌های پیش‌فرض'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _heading('نقشه کامل تهران بدون اینترنت'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        offline.installed
                            ? Icons.offline_pin
                            : Icons.map_outlined,
                      ),
                      title: const Text('بسته نقشه آفلاین تهران'),
                      subtitle: Text(status),
                    ),
                    if (offline.error != null)
                      Text(
                        offline.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (offline.checkError != null)
                      Text(
                        offline.checkError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed:
                          !offline.ready || offline.checking || offline.busy
                          ? null
                          : () => offline.checkForUpdates(),
                      icon: const Icon(Icons.sync),
                      label: Text(
                        offline.checking
                            ? 'در حال بررسی نسخه…'
                            : offline.checkError != null
                            ? 'تلاش دوباره برای بررسی'
                            : 'بررسی نسخهٔ جدید نقشه',
                      ),
                    ),
                    if (offline.availableRelease != null)
                      Text(
                        'نسخهٔ منتشرشده: ' +
                            persianDigits(offline.availableRelease!.edition) +
                            (offline.updateAvailable
                                ? ' · قابل به‌روزرسانی'
                                : ''),
                      ),
                    if (offline.busy) ...[
                      LinearProgressIndicator(value: offline.progress),
                      const SizedBox(height: 8),
                      Text(
                        offline.progress == null
                            ? 'در حال دریافت و اعتبارسنجی…'
                            : 'دریافت: ' +
                                  persianDigits(
                                    (offline.progress! * 100).round(),
                                  ) +
                                  '٪',
                      ),
                      OutlinedButton(
                        onPressed: offline.cancelDownload,
                        child: const Text('لغو دانلود'),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: offline.ready ? _downloadMap : null,
                        icon: const Icon(Icons.download_for_offline_outlined),
                        label: Text(
                          offline.installed
                              ? 'دریافت نسخه جدید نقشه'
                              : 'دانلود نقشه تهران برای استفاده آفلاین',
                        ),
                      ),
                    ],
                    OutlinedButton.icon(
                      onPressed: offline.ready && !offline.busy
                          ? _importMap
                          : null,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('وارد کردن فایل نقشه از دستگاه'),
                    ),
                    if (offline.installed && !offline.busy)
                      TextButton.icon(
                        onPressed: _deleteMap,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('حذف بسته آفلاین'),
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'دانلود فقط با انتخاب شما انجام می‌شود. '
                      'پس از نصب، نقشه خیابان‌ها بدون اتصال اینترنت باز می‌شود.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('بررسی تناوبی نقشه'),
                    subtitle: const Text(
                      'هنگام بازگشت به برنامه. دانلود با تأیید شما انجام می‌شود.',
                    ),
                    trailing: DropdownButton<String>(
                      value:
                          const [
                            'weekly',
                            'monthly',
                            'quarterly',
                            'off',
                          ].contains(offline.cadence)
                          ? offline.cadence
                          : 'quarterly',
                      items: const [
                        DropdownMenuItem(value: 'weekly', child: Text('هفتگی')),
                        DropdownMenuItem(
                          value: 'monthly',
                          child: Text('ماهانه'),
                        ),
                        DropdownMenuItem(
                          value: 'quarterly',
                          child: Text('فصلی'),
                        ),
                        DropdownMenuItem(value: 'off', child: Text('خاموش')),
                      ],
                      onChanged: offline.ready
                          ? (value) {
                              if (value != null) offline.setCadence(value);
                            }
                          : null,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: const Text('منبع جایگزین نقشه'),
                    subtitle: offline.mirror.isEmpty
                        ? null
                        : Text(
                            offline.mirror,
                            textDirection: TextDirection.ltr,
                          ),
                    onTap: _editMirror,
                  ),
                  SwitchListTile.adaptive(
                    title: const Text('استفاده از نقشهٔ آفلاین'),
                    value: offline.preferOffline,
                    onChanged: offline.installed
                        ? offline.setPreferOffline
                        : null,
                  ),
                ],
              ),
            ),
            _heading('موقعیت مکانی'),
            Card(
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    title: const Text('نمایش موقعیت زنده من'),
                    subtitle: const Text(
                      'فقط هنگام استفاده از نقشه و پس از اجازه اندروید',
                    ),
                    value: locationEnabled,
                    onChanged: (v) {
                      setState(() => locationEnabled = v);
                      _savePref('raha_location_enabled', v);
                    },
                  ),
                  SwitchListTile.adaptive(
                    title: const Text('دنبال‌کردن موقعیت'),
                    subtitle: const Text('با حرکت دستی نقشه متوقف می‌شود'),
                    value: followLocation,
                    onChanged: locationEnabled
                        ? (v) {
                            setState(() => followLocation = v);
                            _savePref('raha_follow_location', v);
                          }
                        : null,
                  ),
                ],
              ),
            ),
            _heading('به‌روزرسانی برنامه'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.system_update),
                title: const Text('بررسی دستی نسخهٔ جدید برنامه'),
                trailing: checkingApp
                    ? const CircularProgressIndicator()
                    : const Icon(Icons.chevron_left),
                onTap: checkingApp ? null : _checkAppUpdate,
              ),
            ),
            _heading('حرکت اتوبوس و BRT'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('وارد کردن فایل زمان‌بندی'),
                subtitle: const Text('ثبت و ویرایش دستی در جزئیات هر ایستگاه'),
                onTap: _importTimetable,
              ),
            ),
            _heading('درباره رها تهران'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('درباره برنامه'),
                    subtitle: Text(
                      packageInfo == null
                          ? 'رها تهران · اطلاعات نسخه'
                          : 'نسخه ' +
                                persianDigits(packageInfo!.version) +
                                ' · ساخت ' +
                                persianDigits(packageInfo!.buildNumber),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      textDirection: TextDirection.rtl,
                    ),
                    onTap: () => showAboutDialog(
                      context: context,
                      applicationName: 'رها تهران',
                      applicationVersion: packageInfo == null
                          ? null
                          : persianDigits(packageInfo!.version) +
                                ' (ساخت ' +
                                persianDigits(packageInfo!.buildNumber) +
                                ')',
                      applicationLegalese:
                          '© OpenStreetMap contributors · ODbL',
                      children: const [
                        Text(
                          'اطلاعات مترو و BRT و اتوبوس از داده‌های '
                          'متن‌باز تهیه شده است. مسیرها شماتیک و '
                          'زمان‌های سفر تقریبی‌اند. برای نمایش نقشه '
                          'خیابان‌های تهران بدون اینترنت، دانلود '
                          'اختیاری نقشه در تنظیمات را انتخاب کنید.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _heading('نسخه و سازگاری'),
            const Card(
              child: ListTile(
                leading: Icon(Icons.system_update_alt),
                title: Text('به‌روزرسانی برنامه'),
                subtitle: Text(
                  'آپدیت مستقیم اندروید به شناسه ثابت، شماره نسخه بالاتر '
                  'و امضای یکسان نیاز دارد. نسخه‌های آزمایشی قبلی '
                  'ممکن است امضای متفاوتی داشته باشند.',
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '© OpenStreetMap contributors · داده‌های ایستگاه‌ها: ODbL. '
                'برای استفاده آفلاین از بسته نقشه مستقل و دارای مجوز استفاده می‌شود.',
                style: TextStyle(fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.offlineMap.removeListener(_refresh);
    widget.colors.removeListener(_refresh);
    super.dispose();
  }
}
