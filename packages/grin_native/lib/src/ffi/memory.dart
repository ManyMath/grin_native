import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:grin_native/grin.dart';
import 'package:meta/meta.dart';

import 'bindings.g.dart' as bindings;

/// Turns a native result into its data, or throws its error.
///
/// Returns a copy of `res.data`, or null when the call returns nothing. On
/// failure it parses `res.error` and throws the matching [GrinException].
/// The result is freed with `grin_ffi_result_free` on every path, so call
/// this exactly once per result and do not touch `res` afterwards.
///
/// The returned text may hold a mnemonic. A Dart string cannot be wiped, so
/// callers should keep it only as long as they need it.
String? unwrapFfiResult(bindings.GrinFfiResult res) {
  try {
    if (res.code == 0) {
      return res.data == nullptr ? null : res.data.cast<Utf8>().toDartString();
    }
    final error = res.error == nullptr
        ? jsonEncode(<String, Object?>{
            'code': res.code,
            'message': 'the native call failed without an error message',
          })
        : res.error.cast<Utf8>().toDartString();
    throw GrinException.fromJson(res.code, error);
  } finally {
    bindings.grin_ffi_result_free(res);
  }
}

/// An [Allocator] that overwrites every block with zeros before it is freed.
///
/// It records the size of each allocation, so the whole block is cleared
/// whatever type it was allocated as. Use it through [usingSecretArena].
@visibleForTesting
final class ZeroingAllocator implements Allocator {
  /// Creates an allocator that gets its memory from [inner].
  ZeroingAllocator([this.inner = malloc]);

  /// The allocator that provides and releases the memory.
  final Allocator inner;

  final Map<int, int> _sizes = <int, int>{};

  /// Number of blocks that are allocated and not yet freed.
  int get liveBlocks => _sizes.length;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final pointer = inner.allocate<T>(byteCount, alignment: alignment);
    _sizes[pointer.address] = byteCount;
    return pointer;
  }

  @override
  void free(Pointer<NativeType> pointer) {
    final size = _sizes.remove(pointer.address);
    if (size != null && size > 0) {
      pointer.cast<Uint8>().asTypedList(size).fillRange(0, size, 0);
    }
    inner.free(pointer);
  }
}

/// Runs [body] with an [Arena] whose allocations are zeroed when it ends.
///
/// Use it for anything that carries a password, a mnemonic or an API secret.
/// The arena is released on every path, including when [body] throws.
T usingSecretArena<T>(T Function(Arena arena) body) {
  final arena = Arena(ZeroingAllocator());
  try {
    return body(arena);
  } finally {
    arena.releaseAll();
  }
}

/// Throws [ArgumentError] if [value] has a NUL character.
///
/// The native side reads every string up to its first NUL, so a string with
/// one inside would be cut short without any error. The message never holds
/// the value, because it may be a password.
void _rejectNul(String value) {
  if (value.contains('\u0000')) {
    throw ArgumentError(
      'a string passed to the native library must not contain U+0000',
    );
  }
}

/// Copies [value] to a NUL-terminated UTF-8 string owned by [arena].
///
/// Throws [ArgumentError] if [value] contains U+0000.
Pointer<Char> toCString(String value, Allocator arena) {
  _rejectNul(value);
  return value.toNativeUtf8(allocator: arena).cast<Char>();
}

/// Like [toCString], or a null pointer when [value] is null.
Pointer<Char> toCStringOrNull(String? value, Allocator arena) =>
    value == null ? nullptr : toCString(value, arena);

/// Copies a secret to a NUL-terminated UTF-8 string owned by [arena].
///
/// [arena] should come from [usingSecretArena], which zeroes the copy on
/// release. The temporary UTF-8 bytes made on the way are zeroed here. The
/// Dart [String] itself cannot be wiped.
///
/// Throws [ArgumentError] if [value] contains U+0000.
Pointer<Char> toCStringSecret(String value, Allocator arena) {
  _rejectNul(value);
  final bytes = utf8.encode(value);
  try {
    final pointer = arena.allocate<Uint8>(bytes.length + 1);
    final view = pointer.asTypedList(bytes.length + 1);
    view.setRange(0, bytes.length, bytes);
    view[bytes.length] = 0;
    return pointer.cast<Char>();
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Like [toCStringSecret], or a null pointer when [value] is null.
Pointer<Char> toCStringSecretOrNull(String? value, Allocator arena) =>
    value == null ? nullptr : toCStringSecret(value, arena);
