/// Persian-only display of identifiers while keeping raw IDs ASCII in storage.
/// Accepts ASCII and Arabic-Indic numerals for user search.
String persianDigits(Object? value) {
  final input = value?.toString() ?? '';
  const latin = '0123456789';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  return input.replaceAllMapped(RegExp(r'[0-9]'),
      (m) => persian[latin.indexOf(m.group(0)!)]);
}

String asciiDigits(String input) {
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  return input.replaceAllMapped(RegExp(r'[۰-۹٠-٩]'), (m) {
    final digit = m.group(0)!;
    final p = persian.indexOf(digit);
    final a = arabic.indexOf(digit);
    return (p >= 0 ? p : a).toString();
  });
}
