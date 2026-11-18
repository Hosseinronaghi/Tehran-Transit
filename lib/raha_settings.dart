import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'offline_map.dart';
import 'persian_digits.dart';

class RahaSettingsPage extends StatefulWidget {
  final OfflineMapController offlineMap;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const RahaSettingsPage({
    super.key,
    required this.offlineMap,
    required this.themeMode,
    required this.onThemeChanged,
  });
  @override
  State<RahaSettingsPage> createState() => _RahaSettingsPageState();
}

class _RahaSettingsPageState extends State<RahaSettingsPage> {
  bool quarterlyReminder = true;
  late ThemeMode selectedTheme;
  @override
  void initState() {
    super.initState();
    selectedTheme = widget.themeMode;
    widget.offlineMap.addListener(_refresh);
    _readPrefs();
  }

  Future<void> _readPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() {
      quarterlyReminder = prefs.getBool('raha_quarterly_map_reminder') ?? true;
    });
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
              child: const Text('انصراف')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف نقشه')),
        ],
      ),
    );
    if (confirmed == true) await widget.offlineMap.remove();
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final offline = widget.offlineMap;
    final age = offline.installedAt == null
        ? null
        : DateTime.now().difference(offline.installedAt!).inDays;
    final status = offline.installed
        ? 'نصب‌شده · ' + persianDigits(
            (offline.installedBytes / (1024 * 1024)).toStringAsFixed(1)) +
            ' مگابایت · نسخه ' +
            persianDigits(offline.installedEdition)
        : 'نقشه خیابان‌های تهران هنوز دانلود نشده است.';
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تنظیمات رها تهران')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _heading('ظاهر برنامه'),
          Card(
            child: Column(children: [
              const ListTile(
                leading: Icon(Icons.font_download_outlined),
                title: Text('فونت برنامه'),
                subtitle: Text('وزیر (Vazir)'),
              ),
              const ListTile(
                leading: Icon(Icons.format_list_numbered_rtl),
                title: Text('اعداد خطوط'),
                subtitle: Text('نمایش فارسی؛ جست‌وجو با ارقام فارسی یا انگلیسی'),
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
            ]),
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
                      offline.installed ? Icons.offline_pin : Icons.map_outlined,
                    ),
                    title: const Text('بسته نقشه آفلاین تهران'),
                    subtitle: Text(status),
                  ),
                  if (offline.error != null)
                    Text(offline.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        )),
                  if (quarterlyReminder &&
                      offline.installed &&
                      age != null &&
                      age >= 90)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'بیش از یک فصل از نسخه فعلی نقشه گذشته است. '
                        'در صورت انتشار بسته جدید، آن را بررسی کنید.',
                      ),
                    ),
                  if (!offline.canCheck)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'بسته معتبر و میزبانی‌شده نقشه تهران هنوز '
                        'منتشر نشده است. فعلاً فقط خطوط و ایستگاه‌ها '
                        'آفلاین‌اند؛ دکمه دانلود تا انتشار بسته غیرفعال است.',
                      ),
                    ),
                  if (offline.canCheck && !offline.downloadable)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'ابتدا انتشار بسته جدید نقشه را بررسی کنید. '
                        'دانلود خودکار نخواهد بود.',
                      ),
                    ),
                  if (offline.canCheck)
                    OutlinedButton.icon(
                      onPressed: offline.checking || offline.busy
                          ? null
                          : () => offline.checkForUpdates(),
                      icon: const Icon(Icons.sync),
                      label: Text(offline.checking
                          ? 'در حال بررسی نسخه…'
                          : 'بررسی نسخه جدید نقشه'),
                    ),
                  if (offline.availableRelease != null)
                    Text('نسخه منتشرشده: ' +
                        persianDigits(offline.availableRelease!.edition) +
                        (offline.updateAvailable
                            ? ' · قابل به‌روزرسانی'
                            : offline.installed
                                ? ' · نصب‌شده'
                                : ' · آماده دانلود')),
                  if (offline.busy) ...[
                    LinearProgressIndicator(value: offline.progress),
                    const SizedBox(height: 8),
                    Text(offline.progress == null
                        ? 'در حال دریافت و اعتبارسنجی…'
                        : 'دریافت: ' +
                            persianDigits(
                              (offline.progress! * 100).round(),
                            ) +
                            '٪'),
                    OutlinedButton(
                      onPressed: offline.cancelDownload,
                      child: const Text('لغو دانلود'),
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: offline.downloadable &&
                              (!offline.installed || offline.updateAvailable)
                          ? () => offline.download()
                          : null,
                      icon: const Icon(Icons.download_for_offline_outlined),
                      label: Text(offline.installed
                          ? 'دریافت نسخه جدید نقشه'
                          : 'دانلود نقشه تهران برای استفاده آفلاین'),
                    ),
                  ],
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
            child: SwitchListTile.adaptive(
              title: const Text('یادآوری به‌روزرسانی فصلی نقشه'),
              subtitle: const Text(
                'بعد از سه ماه، هنگام مراجعه به تنظیمات '
                'قدیمی بودن نقشه را یادآوری کن؛ دانلود خودکار انجام نمی‌شود.',
              ),
              value: quarterlyReminder,
              onChanged: (v) async {
                setState(() => quarterlyReminder = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('raha_quarterly_map_reminder', v);
              },
            ),
          ),
          _heading('حرکت اتوبوس و BRT'),
          const Card(
            child: ListTile(
              leading: Icon(Icons.schedule_outlined),
              title: Text('زمان رسیدن یا حرکت'),
              subtitle: Text(
                'برای هر ایستگاه بخش بازشونده وجود دارد؛ '
                'اما تا اتصال منبع برنامه زمان‌بندی معتبر، '
                'زمانی به‌صورت ساختگی نمایش داده نمی‌شود.',
              ),
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
        ]),
      ),
    );
  }

  @override
  void dispose() {
    widget.offlineMap.removeListener(_refresh);
    super.dispose();
  }
}
