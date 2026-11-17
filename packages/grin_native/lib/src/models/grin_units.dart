/// Constants for the unit of account.
abstract final class GrinUnits {
  /// Nanogrin in one grin.
  static final BigInt nanogrinPerGrin = BigInt.from(1000000000);

  /// Decimal places of a grin amount.
  static const int decimals = 9;
}

/// Formats [nanogrin] as a decimal grin amount without rounding.
///
/// Trailing zeros are dropped, and so is the point when nothing follows it:
/// `1500000000` gives `1.5`, `2000000000` gives `2` and `1` gives
/// `0.000000001`.
String formatGrin(BigInt nanogrin) {
  final negative = nanogrin.isNegative;
  final digits = nanogrin.abs().toString().padLeft(GrinUnits.decimals + 1, '0');
  final split = digits.length - GrinUnits.decimals;
  final whole = digits.substring(0, split);
  final fraction = digits.substring(split).replaceFirst(RegExp(r'0+$'), '');
  final text = fraction.isEmpty ? whole : '$whole.$fraction';
  return negative ? '-$text' : text;
}

final RegExp _grinAmount = RegExp(r'^(\d+)(?:\.(\d{1,9}))?$');

/// Parses a decimal grin amount such as `1`, `1.5` or `0.000000001` into
/// nanogrin.
///
/// Surrounding white space is ignored. More than nine decimals, a sign, an
/// exponent or a separator other than the point throw a [FormatException],
/// because rounding an amount silently is never right.
BigInt parseGrin(String text) {
  final match = _grinAmount.firstMatch(text.trim());
  if (match == null) {
    throw FormatException('not a grin amount with at most 9 decimals', text);
  }
  final whole = BigInt.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(GrinUnits.decimals, '0');
  return whole * GrinUnits.nanogrinPerGrin + BigInt.parse(fraction);
}
