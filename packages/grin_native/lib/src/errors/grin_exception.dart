import 'dart:convert';

import '../internal/json_helpers.dart';

/// Base class of every error reported by the native Grin library.
///
/// There is one subclass per error code in the grin-ffi contract. The class
/// is sealed, so a `switch` over
/// a [GrinException] is checked for completeness. A code this version of the
/// package does not know maps to [GrinUnknownException].
sealed class GrinException implements Exception {
  /// Creates an exception for the native error [code].
  const GrinException(this.code, this.message, [this.details]);

  /// Builds the exception for [code] from the native error JSON
  /// `{"code", "message", "details"}`.
  ///
  /// [code] wins over the `code` member of the JSON. A text that is not a
  /// JSON object becomes the message as it is.
  factory GrinException.fromJson(int code, String errorJson) {
    var message = errorJson;
    Map<String, Object?>? details;
    try {
      final Object? decoded = jsonDecode(errorJson);
      if (decoded is Map<String, Object?>) {
        final Object? text = decoded['message'];
        message = text is String ? text : errorJson;
        final Object? extra = decoded['details'];
        if (extra is Map<String, Object?>) details = extra;
      }
    } on FormatException {
      // Keep the raw text as the message.
    }
    return switch (code) {
      1 => GrinInvalidArgumentException._(code, message, details),
      2 => GrinInvalidUtf8Exception._(code, message, details),
      3 => GrinJsonException._(code, message, details),
      4 => GrinWalletNotFoundException._(code, message, details),
      5 => GrinInvalidPasswordException._(code, message, details),
      6 => GrinWalletExistsException._(code, message, details),
      7 => GrinInvalidHandleException._(code, message, details),
      8 => GrinLifecycleException._(code, message, details),
      9 => GrinNodeException._(code, message, details),
      10 => GrinInsufficientFundsException._(code, message, details),
      11 => GrinSlateException._(code, message, details),
      12 => GrinTransactionException._(code, message, details),
      13 => GrinNotFoundException._(code, message, details),
      14 => GrinCancelledException._(code, message, details),
      15 => GrinIoException._(code, message, details),
      16 => GrinInternalPanicException._(code, message, details),
      17 => GrinInternalException._(code, message, details),
      18 => GrinWalletBusyException._(code, message, details),
      19 => GrinHttpException._(code, message, details),
      20 => GrinNotSupportedException._(code, message, details),
      21 => GrinInvalidAddressException._(code, message, details),
      22 => GrinInvalidMnemonicException._(code, message, details),
      _ => GrinUnknownException._(code, message, details),
    };
  }

  /// The `GrinErrorCode` value reported by the native library.
  final int code;

  /// English text for logs. It is not stable, so do not parse it.
  final String message;

  /// Structured data for some codes, or null.
  final Map<String, Object?>? details;

  /// The `wallet_dir` entry of [details], if there is one.
  String? get _walletDir {
    final Object? value = details?['wallet_dir'];
    return value is String ? value : null;
  }

  /// The id of the slate the failed call was working on, if the library
  /// reports one in [details].
  ///
  /// A call can fail after the transaction was finalized, for example when
  /// the broadcast is refused. This is the id to pass to `repost` or
  /// `cancelTransaction` then. Null when the error carries none.
  String? get slateId {
    final Object? value = details?['slate_id'];
    return value is String ? value : null;
  }

  /// True when the call failed after the transaction was finalized: the
  /// wallet holds a complete transaction that did not reach the node.
  ///
  /// The inputs stay locked. Pass [slateId] to `repost` to broadcast it
  /// again, or to `cancelTransaction` to give it up. A counterparty who
  /// holds the finalized transaction could still post it after a cancel.
  bool get finalized => details?['finalized'] == true;

  /// True when a synchronous send locked its inputs, could not be
  /// finalized, and was cancelled again by the library before the call
  /// returned: nothing is locked and nothing was sent.
  ///
  /// The recipient may still hold its half of the exchange, which is
  /// useless without the sender's signature. [slateId] names the cancelled
  /// transaction in the history.
  bool get released => details?['released'] == true;

  /// The last height a scan saved before it stopped, when the error says so.
  ///
  /// A cancelled scan reports it, and so does a scan that failed part way,
  /// for example on a node error: every block up to this height is saved
  /// and the next scan can start one above it. It can be one below the
  /// height the scan was asked to start from, when nothing was saved. Null
  /// when the scan never started or failed before it read the chain tip;
  /// start again from the same height then.
  int? get scannedHeight {
    final Object? value = details?['scanned_height'];
    return value is int ? value : null;
  }

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Code 1: a NULL, out-of-range value, bad URL or proxy, or a handle for
/// another directory.
final class GrinInvalidArgumentException extends GrinException {
  const GrinInvalidArgumentException._(
    super.code,
    super.message,
    super.details,
  );
}

/// Code 2: a string argument was not valid UTF-8.
final class GrinInvalidUtf8Exception extends GrinException {
  const GrinInvalidUtf8Exception._(super.code, super.message, super.details);
}

/// Code 3: a JSON argument did not parse or missed a required key.
final class GrinJsonException extends GrinException {
  const GrinJsonException._(super.code, super.message, super.details);
}

/// Code 4: there is no wallet in the directory.
final class GrinWalletNotFoundException extends GrinException {
  const GrinWalletNotFoundException._(super.code, super.message, super.details);

  /// The wallet directory exactly as the caller gave it (the parent of
  /// `wallet_data`, not resolved), or null if the native library did not
  /// say. Unlike [GrinWalletBusyException.walletDir], it can be compared
  /// with the `walletDir` the call was made with.
  String? get walletDir => _walletDir;
}

/// Code 5: the password does not decrypt `wallet.seed`.
final class GrinInvalidPasswordException extends GrinException {
  const GrinInvalidPasswordException._(
    super.code,
    super.message,
    super.details,
  );
}

/// Code 6: the directory already holds a wallet.
final class GrinWalletExistsException extends GrinException {
  const GrinWalletExistsException._(super.code, super.message, super.details);

  /// The wallet directory exactly as the caller gave it (the parent of
  /// `wallet_data`, not resolved), or null if the native library did not
  /// say. Unlike [GrinWalletBusyException.walletDir], it can be compared
  /// with the `walletDir` the call was made with.
  String? get walletDir => _walletDir;
}

/// Code 7: the handle is 0, unknown or already closed.
final class GrinInvalidHandleException extends GrinException {
  const GrinInvalidHandleException._(super.code, super.message, super.details);
}

/// Code 8: another wallet open, close or seed failure.
final class GrinLifecycleException extends GrinException {
  const GrinLifecycleException._(super.code, super.message, super.details);
}

/// Code 9: the node could not be reached or gave an unusable answer.
final class GrinNodeException extends GrinException {
  const GrinNodeException._(super.code, super.message, super.details);
}

/// Code 10: not enough spendable funds.
final class GrinInsufficientFundsException extends GrinException {
  const GrinInsufficientFundsException._(
    super.code,
    super.message,
    super.details,
  );

  /// The amount the transaction needs, in nanogrin, or null if the native
  /// library did not say or the value is not a non-negative integer (or
  /// integer string). Never throws.
  ///
  /// grin_native reports at most 2^63 - 1 here: a larger sum (an amount at
  /// the cap plus its fee) is given as that value.
  BigInt? get required => _amount('required');

  /// The amount that can be spent now, in nanogrin, or null if the native
  /// library did not say or the value is not a non-negative integer (or
  /// integer string). Never throws.
  BigInt? get available => _amount('available');

  BigInt? _amount(String key) {
    try {
      return readBigInt(details?[key], key);
    } on FormatException {
      // Missing or malformed. A getter on an exception should not throw
      // while the caller is handling it.
      return null;
    }
  }
}

/// Code 11: a slate or Slatepack could not be parsed, encrypted, decrypted
/// or is in the wrong state.
final class GrinSlateException extends GrinException {
  const GrinSlateException._(super.code, super.message, super.details);
}

/// Code 12: transaction building or bookkeeping failed.
final class GrinTransactionException extends GrinException {
  const GrinTransactionException._(super.code, super.message, super.details);
}

/// Code 13: the transaction or payment proof does not exist.
final class GrinNotFoundException extends GrinException {
  const GrinNotFoundException._(super.code, super.message, super.details);
}

/// Code 14: a scan was cancelled. For a scan stopped between batches,
/// `details` carry the last saved `scanned_height` and the `tip_height`. For
/// a scan that was cancelled before it started (still queued, or the wallet
/// was closed first), `details` are null.
final class GrinCancelledException extends GrinException {
  const GrinCancelledException._(super.code, super.message, super.details);
}

/// Code 15: a file system error.
final class GrinIoException extends GrinException {
  const GrinIoException._(super.code, super.message, super.details);
}

/// Code 16: the native library caught a Rust panic. The message holds the
/// panic text.
final class GrinInternalPanicException extends GrinException {
  const GrinInternalPanicException._(super.code, super.message, super.details);
}

/// Code 17: an unexpected internal error.
final class GrinInternalException extends GrinException {
  const GrinInternalException._(super.code, super.message, super.details);
}

/// Code 18: the wallet directory is held by an open wallet or one that is
/// still closing, or a scan is already running on the wallet.
///
/// The package reports this error and never retries it. Whoever holds the
/// directory may be a long send or a scan, so a retry would mostly hide a
/// client that was never closed.
final class GrinWalletBusyException extends GrinException {
  const GrinWalletBusyException._(super.code, super.message, super.details);

  /// The canonical path of the busy `wallet_data` directory itself
  /// (`<walletDir>/wallet_data` with links and `.` or `..` resolved), or
  /// null if the native library did not say.
  ///
  /// This is not the directory the caller passed: it never equals
  /// `GrinWalletApi.walletDir`, and two different spellings of one
  /// wallet give the same value here. [GrinWalletNotFoundException.walletDir]
  /// and [GrinWalletExistsException.walletDir], by contrast, carry the
  /// directory as the caller gave it.
  String? get walletDir => _walletDir;

  /// True when the cause is a scan already running on the wallet, rather
  /// than an open wallet in the directory.
  bool get isScanInProgress => details?['reason'] == 'scan_in_progress';
}

/// Code 19: wallet-to-wallet HTTP communication failed.
final class GrinHttpException extends GrinException {
  const GrinHttpException._(super.code, super.message, super.details);
}

/// Code 20: the function is not implemented in this build.
final class GrinNotSupportedException extends GrinException {
  const GrinNotSupportedException._(super.code, super.message, super.details);
}

/// Code 21: not a valid slatepack address, onion address or URL, or an
/// address for the other network.
final class GrinInvalidAddressException extends GrinException {
  const GrinInvalidAddressException._(super.code, super.message, super.details);
}

/// Code 22: a bad word, checksum or length in a mnemonic.
final class GrinInvalidMnemonicException extends GrinException {
  const GrinInvalidMnemonicException._(
    super.code,
    super.message,
    super.details,
  );
}

/// A code this version of the package has no class for. Codes are only ever
/// appended, so this means the native library is newer than the Dart code.
final class GrinUnknownException extends GrinException {
  const GrinUnknownException._(super.code, super.message, super.details);
}
