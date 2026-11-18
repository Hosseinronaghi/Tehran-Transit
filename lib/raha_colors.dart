import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-selected app and transit layer colors.
///
/// Preferences are kept independently of APK and map archive upgrades.
class RahaColors extends ChangeNotifier {
  static const choices = <Color>[
    Color(0xff087d86), // turquoise
    Color(0xff2563eb), // blue
    Color(0xff7257ca), // violet
    Color(0xffdc5681), // rose
    Color(0xffe05648), // coral
    Color(0xffda8b22), // amber
    Color(0xff12916f), // green
    Color(0xff41566f), // slate
  ];

  static const labels = <String, String>{
    'accent': 'رنگ اصلی رابط',
    'metro': 'نشانگرها و مسیرهای مترو',
    'brt': 'نشانگرها و مسیرهای BRT',
    'bus': 'نشانگرها و مسیرهای اتوبوس',
    'route': 'مسیر پیشنهادی مسیریابی',
  };

  static const defaults = <String, Color>{
    'accent': Color(0xff087d86),
    'metro': Color(0xff2563eb),
    'brt': Color(0xffe05648),
    'bus': Color(0xff12916f),
    'route': Color(0xff7257ca),
  };

  final Map<String, Color> _selected = {...defaults};

  // In custom mode, all drawn line segments use the chosen mode color.
  // Source-specific line colors remain available as an explicit alternative.
  bool useSourceLineColors = false;

  Color forPart(String key) => _selected[key] ?? defaults[key] ?? choices.first;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in defaults.entries) {
      final saved = prefs.getInt('raha_color_' + entry.key);
      if (saved != null) {
        _selected[entry.key] = Color(saved);
      }
    }
    useSourceLineColors = prefs.getBool('raha_source_line_colors') ?? false;
    notifyListeners();
  }

  Future<void> setColor(String key, Color color) async {
    if (!defaults.containsKey(key) || !choices.contains(color)) return;
    _selected[key] = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('raha_color_' + key, color.toARGB32());
  }

  Future<void> setUseSourceLineColors(bool selected) async {
    useSourceLineColors = selected;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('raha_source_line_colors', selected);
  }

  Future<void> reset() async {
    _selected
      ..clear()
      ..addAll(defaults);
    useSourceLineColors = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    for (final key in defaults.keys) {
      await prefs.remove('raha_color_' + key);
    }
    await prefs.remove('raha_source_line_colors');
  }
}
