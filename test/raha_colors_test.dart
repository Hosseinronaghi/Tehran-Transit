import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tehran_transit/raha_colors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('palette defaults to distinct colors for five independently configurable parts', () async {
    final palette = RahaColors();
    await palette.load();
    expect(palette.forPart('accent'), const Color(0xff087d86));
    expect(palette.forPart('metro'), const Color(0xff2563eb));
    expect(palette.forPart('brt'), const Color(0xffe05648));
    expect(palette.forPart('bus'), const Color(0xff12916f));
    expect(palette.useSourceLineColors, isFalse);
    palette.dispose();
  });

  test('custom palette is persistent and can be reset', () async {
    final palette = RahaColors();
    await palette.load();
    const custom = Color(0xff7257ca);
    await palette.setColor('metro', custom);
    await palette.setColor('accent', const Color(0xffdc5681));
    await palette.setUseSourceLineColors(true);

    final restored = RahaColors();
    await restored.load();
    expect(restored.forPart('metro'), custom);
    expect(restored.forPart('accent'), const Color(0xffdc5681));
    expect(restored.useSourceLineColors, isTrue);

    await restored.reset();
    final afterReset = RahaColors();
    await afterReset.load();
    expect(afterReset.forPart('metro'), RahaColors.defaults['metro']);
    expect(afterReset.useSourceLineColors, isFalse);
    palette.dispose();
    restored.dispose();
    afterReset.dispose();
  });

  test('unsupported color choices never override saved palette values', () async {
    final palette = RahaColors();
    await palette.load();
    final original = palette.forPart('bus');
    await palette.setColor('bus', const Color(0xff010203));
    expect(palette.forPart('bus'), original);
    palette.dispose();
  });
}
