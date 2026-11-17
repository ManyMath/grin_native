import 'dart:convert';

/// Decodes [text] as a JSON object, or throws a [FormatException].
Map<String, Object?> decodeJsonObject(String? text) {
  if (text == null) {
    throw const FormatException('the native call returned no data');
  }
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('expected a JSON object');
  }
  return decoded;
}

/// Reads an unsigned integer amount (nanogrin) as a [BigInt].
///
/// Accepts a JSON integer or a decimal string. grin_native writes every
/// amount as a JSON integer of at most 2^63 - 1, so
/// the VM's decoder always yields an [int]; the one string amount is in
/// libwallet's payment proof format. A backend whose JSON decoder cannot
/// hold 64-bit integers exactly (JavaScript holds 2^53) must write amounts
/// as decimal strings. A negative value is a [FormatException].
BigInt readBigInt(Object? value, String key) {
  final BigInt? parsed = switch (value) {
    int() => BigInt.from(value),
    String() => BigInt.tryParse(value),
    _ => null,
  };
  if (parsed == null) {
    throw FormatException('"$key" is not an integer', value);
  }
  // Amounts and heights are unsigned in the native library.
  if (parsed.isNegative) {
    throw FormatException('"$key" is negative', value);
  }
  return parsed;
}

/// Reads a JSON integer that fits an [int].
int readInt(Object? value, String key) {
  if (value is int) return value;
  throw FormatException('"$key" is not an integer', value);
}

/// Reads a JSON boolean.
bool readBool(Object? value, String key) {
  if (value is bool) return value;
  throw FormatException('"$key" is not a boolean', value);
}

/// Reads a JSON string.
String readString(Object? value, String key) {
  if (value is String) return value;
  throw FormatException('"$key" is not a string', value);
}

/// Reads a JSON string that may be null.
String? readOptionalString(Object? value, String key) {
  if (value == null) return null;
  return readString(value, key);
}

/// Reads a JSON integer that may be null.
int? readOptionalInt(Object? value, String key) {
  if (value == null) return null;
  return readInt(value, key);
}

/// Reads an unsigned integer amount that may be null.
BigInt? readOptionalBigInt(Object? value, String key) {
  if (value == null) return null;
  return readBigInt(value, key);
}

/// Reads a JSON array of strings.
List<String> readStringList(Object? value, String key) {
  if (value is List<Object?>) {
    return List<String>.unmodifiable(
      value.map((Object? item) => readString(item, key)),
    );
  }
  throw FormatException('"$key" is not an array', value);
}

/// Reads a JSON object.
Map<String, Object?> readObject(Object? value, String key) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('"$key" is not an object', value);
}

/// Reads an RFC 3339 timestamp as a UTC [DateTime].
DateTime readDateTime(Object? value, String key) {
  final text = readString(value, key);
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    throw FormatException('"$key" is not an RFC 3339 timestamp', value);
  }
  return parsed.toUtc();
}

/// Reads an RFC 3339 timestamp that may be null.
DateTime? readOptionalDateTime(Object? value, String key) {
  if (value == null) return null;
  return readDateTime(value, key);
}

/// Whether two lists hold equal elements in the same order.
bool listsEqual<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The largest amount the native calls take as an `int`.
///
/// Amounts are `u64` natively, but a Dart `int` is signed, so values from
/// 2^63 up would wrap. No real balance gets near it (about 9.2e18 nanogrin).
final BigInt _maxNativeAmount = BigInt.parse('9223372036854775807');

/// Checks that [amount] fits the native `u64` argument and returns it as an
/// `int`.
///
/// Throws [ArgumentError] for a negative value and for one at or above 2^63.
int amountToNative(BigInt amount, [String name = 'amount']) {
  if (amount.isNegative || amount > _maxNativeAmount) {
    throw ArgumentError.value(
      amount,
      name,
      'must be between 0 and 9223372036854775807 nanogrin',
    );
  }
  return amount.toUnsigned(64).toInt();
}

/// Checks that [value] fits a native `u32` argument and returns it.
///
/// Dart passes an `int` to a 32-bit parameter by cutting off the high bits,
/// so an unchecked 2^32 + 5 would arrive as 5. Throws [ArgumentError] unless
/// [value] is between 0 and 4294967295.
int requireU32(int value, String name) {
  if (value < 0 || value > 0xFFFFFFFF) {
    throw ArgumentError.value(value, name, 'must be between 0 and 4294967295');
  }
  return value;
}

/// Checks that [value] fits a native `u64` argument and returns it.
///
/// A Dart `int` is signed, so a negative value would wrap to a huge number
/// natively. Throws [ArgumentError] for a negative [value]; the largest
/// value is 2^63 - 1, which is all an `int` can hold.
int requireU64(int value, String name) {
  if (value < 0) {
    throw ArgumentError.value(value, name, 'must not be negative');
  }
  return value;
}

/// Turns an optional transaction id into the native `i64` argument.
///
/// The native side reads a negative id as "not given", so null becomes -1.
/// An explicit negative id is refused instead of being taken for null, since
/// it would silently fall back to the slate id. Throws [ArgumentError] for a
/// negative [txId].
int txIdToNative(int? txId, [String name = 'txId']) {
  if (txId == null) return -1;
  if (txId < 0) {
    throw ArgumentError.value(
      txId,
      name,
      'must not be negative; pass null to leave it out',
    );
  }
  return txId;
}
