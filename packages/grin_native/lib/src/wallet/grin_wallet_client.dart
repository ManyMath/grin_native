import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:grin_native/codec.dart';
import 'package:grin_native/grin.dart';
import 'package:meta/meta.dart';

import '../ffi/bindings.g.dart' as bindings;
import '../ffi/memory.dart';
import 'grin_native_backend.dart';

/// A typed client for one open Grin wallet: the [GrinWalletApi] of the native
/// backend. The wallet-less operations are static members here, and
/// [GrinNativeBackend] offers them as a [GrinWalletBackend].
///
/// The native library is synchronous, so every wallet operation runs in a
/// short-lived isolate. Operations of one client run one after another in
/// the order they were called; [scanProgress] and [cancelScan] are the two
/// exceptions, because they take no wallet lock and must answer while a scan
/// runs. Amounts are `BigInt` nanogrin; see `formatGrin` and `parseGrin`.
///
/// Errors reach the caller in three ways:
/// - A bad argument ([ArgumentError]: a negative or out of range number, an
///   amount that does not fit the native argument) and use after [close]
///   ([StateError]) are thrown synchronously, before a future exists. They
///   are programming errors, so they do not reach a `catchError` on the
///   returned future. The one bad argument found later is a string with
///   U+0000: it is rejected where it is converted, inside the operation, so
///   its [ArgumentError] arrives through the future.
/// - Everything the native library reports arrives as a [GrinException]
///   through the returned future.
/// - Native output that does not have the documented shape surfaces as a
///   [FormatException], also through the returned future. It means a
///   mismatch between this package and the library, not a wallet problem.
///
/// A queued operation runs whether or not anyone awaits its future, and the
/// queue goes on to the next one when it fails. Its error is only
/// observable through its own future: the queue handles every result, so a
/// failed call that nobody awaits does not reach the zone's uncaught-error
/// handler either. Await the future, or attach a handler, for any call
/// whose failure matters.
///
/// Call [close] when you are done. A client that is dropped without it is
/// closed by a native finalizer when it is garbage collected, but the
/// directory may stay busy until any operation still running has returned.
/// Its [events] stream is then closed too, without [GrinWalletClosed].
class GrinWalletClient implements GrinWalletApi, Finalizable {
  /// Wraps a native wallet [handle].
  ///
  /// Only for code that obtains a handle by other means, such as the test
  /// harness. Use [create] or [open] otherwise. The client takes ownership
  /// of the handle and closes it.
  ///
  /// The native finalizer gets the handle as its pointer token, and on a
  /// 32-bit platform a pointer holds only 32 bits. A handle above
  /// 4294967295 is therefore closed at once and [StateError] is thrown,
  /// rather than leaving a finalizer that would close the wrong handle.
  /// Handles start at 1 and grow by one per successful open, so this takes
  /// 2^32 opens in one process.
  @internal
  GrinWalletClient.fromHandle({
    required int handle,
    required this.walletDir,
    required this.network,
  }) : _handle = handle {
    if (sizeOf<Pointer<Void>>() == 4 && handle > 0xFFFFFFFF) {
      try {
        unwrapFfiResult(bindings.grin_wallet_close(handle));
      } on GrinException {
        // Nothing more can be done with it.
      }
      throw StateError(
        'wallet handle $handle does not fit the native finalizer token on '
        'this 32-bit platform',
      );
    }
    _finalizer.attach(this, Pointer<Void>.fromAddress(handle), detach: this);
    _eventsFinalizer.attach(this, WeakReference(_events), detach: this);
  }

  /// Calls `grin_wallet_close_finalizer` with the handle as the token. A
  /// handle is a non-zero 64-bit number, so it is stored in the pointer
  /// itself and nothing is allocated.
  static final NativeFinalizer _finalizer = NativeFinalizer(
    bindings.addresses.grin_wallet_close_finalizer,
  );

  /// Closes the [events] stream of a client that was garbage collected
  /// without [close], so a listener that still holds its subscription gets
  /// the done event. The native handle is not touched here: [_finalizer]
  /// still closes it. This only releases the Dart side of the stream.
  ///
  /// The token is a weak reference. A subscription's callbacks may refer to
  /// the client, and a finalizer token that reaches the client keeps it
  /// alive forever, which would stop [_finalizer] from running too. If the
  /// controller is gone by then, nobody held a subscription and there is
  /// nothing to close.
  static final Finalizer<WeakReference<StreamController<GrinWalletEvent>>>
  _eventsFinalizer = Finalizer((ref) {
    final controller = ref.target;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  });

  // Static members ----------------------------------------------------------

  /// Sets up native logging to stderr and a panic hook that logs panics.
  ///
  /// [level] is one of `trace`, `debug`, `info`, `warn`, `error` and `off`.
  /// It is a direct call that may be repeated: later calls only change the
  /// level. Throws [GrinInvalidArgumentException] for an unknown level.
  static void initLogs({String level = 'info'}) {
    usingSecretArena((arena) {
      unwrapFfiResult(bindings.grin_init_logs(toCString(level, arena)));
    });
  }

  /// Generates a new BIP39 mnemonic of [wordCount] words (12, 15, 18, 21 or
  /// 24).
  ///
  /// Throws [GrinInvalidArgumentException] for any other count, and
  /// [ArgumentError] for a count that is not between 0 and 4294967295.
  static Future<String> generateMnemonic({int wordCount = 24}) {
    final nativeWordCount = requireU32(wordCount, 'wordCount');
    return Isolate.run(() {
      final json = decodeJsonObject(
        unwrapFfiResult(bindings.grin_mnemonic_generate(nativeWordCount)),
      );
      return readString(json['mnemonic'], 'mnemonic');
    });
  }

  /// Checks a mnemonic. A bad phrase is a result with `valid` false, not an
  /// error.
  static Future<GrinMnemonicValidation> validateMnemonic(String mnemonic) =>
      Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_mnemonic_validate(toCStringSecret(mnemonic, arena)),
            ),
          );
          return GrinMnemonicValidation.fromJson(json);
        });
      });

  /// Checks [address] for [network].
  ///
  /// Accepts a Slatepack address, a v3 onion address (with or without
  /// scheme, `.onion` and `/v2/foreign`) and an `http(s)` URL. Throws
  /// [GrinInvalidAddressException] for anything else, including an address
  /// of the other network.
  static Future<GrinAddressValidation> validateAddress(
    String address,
    GrinNetwork network,
  ) {
    final networkValue = network.value;
    return Isolate.run(() => _validateAddress(address, networkValue));
  }

  /// [validateAddress] on the calling isolate.
  ///
  /// The native check is stateless and takes microseconds, so it can back a
  /// synchronous validator such as Stack Wallet's
  /// `CryptoCurrency.validateAddress`. Same results and exceptions as
  /// [validateAddress].
  static GrinAddressValidation validateAddressSync(
    String address,
    GrinNetwork network,
  ) => _validateAddress(address, network.value);

  static GrinAddressValidation _validateAddress(String address, int network) =>
      usingSecretArena((arena) {
        final json = decodeJsonObject(
          unwrapFfiResult(
            bindings.grin_address_validate(toCString(address, arena), network),
          ),
        );
        return GrinAddressValidation.fromJson(json);
      });

  /// Asks a node for its version and chain tip without a wallet.
  ///
  /// It is stateless, so no wallet's [GrinWalletConfig.networkEnabled]
  /// applies to it.
  ///
  /// Throws [GrinNodeException] when it cannot be reached and
  /// [GrinInvalidArgumentException] for a bad URL or proxy.
  static Future<GrinNodeInfo> testNodeConnection({
    required String nodeUrl,
    String? apiSecret,
    String? socksProxy,
  }) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_node_test_connection(
            toCString(nodeUrl, arena),
            toCStringSecretOrNull(apiSecret, arena),
            toCStringOrNull(socksProxy, arena),
          ),
        ),
      );
      return GrinNodeInfo.fromJson(json);
    });
  });

  /// Creates a wallet in `<config.walletDir>/wallet_data` and opens it.
  ///
  /// With a null [mnemonic] a new 24-word seed is generated; otherwise the
  /// 12 to 24 word phrase is used. Nothing contacts the node.
  ///
  /// [isNewWallet] says whether that phrase was just generated and so has
  /// no history on the chain. When true, the wallet is stored as needing no
  /// scan, as one created without a mnemonic is: its first refresh from the
  /// node looks only at the last 2880 blocks below the tip. Leave it false
  /// to restore a phrase that may have been used before; the first refresh
  /// then scans from the first block, or call [scan] with a start height.
  /// Without a mnemonic it changes nothing.
  ///
  /// Throws [GrinWalletExistsException] if the directory already holds a
  /// wallet, [GrinInvalidMnemonicException] for a bad phrase and
  /// [GrinInvalidArgumentException] for a bad configuration.
  ///
  /// Throws [GrinWalletBusyException] when another wallet in this process
  /// holds the directory, or one that was closed is still finishing a call.
  /// The error is reported as it is and never retried. Close the other
  /// client, reuse it, or let the caller decide whether to wait.
  static Future<GrinWalletClient> create({
    required GrinWalletConfig config,
    String? mnemonic,
    required String password,
    bool isNewWallet = false,
  }) async {
    final configJson = jsonEncode(config.toJson());
    final handle = await Isolate.run(() {
      return usingSecretArena((arena) {
        final json = decodeJsonObject(
          unwrapFfiResult(
            bindings.grin_wallet_create(
              toCStringSecret(configJson, arena),
              toCStringSecretOrNull(mnemonic, arena),
              toCStringSecret(password, arena),
              isNewWallet,
            ),
          ),
        );
        return readInt(json['handle'], 'handle');
      });
    });
    return GrinWalletClient.fromHandle(
      handle: handle,
      walletDir: config.walletDir,
      network: config.network,
    );
  }

  /// Opens the wallet in `<config.walletDir>/wallet_data`. Nothing contacts
  /// the node.
  ///
  /// Throws [GrinWalletNotFoundException] if there is no wallet and
  /// [GrinInvalidPasswordException] for a wrong password.
  ///
  /// A directory can be held by one wallet per process. Throws
  /// [GrinWalletBusyException] (with `walletDir`) if it is open already, or
  /// if a wallet that was closed has a call that has not returned yet. After
  /// `await client.close()` the directory is always free again. The error is
  /// reported as it is and never retried.
  static Future<GrinWalletClient> open({
    required GrinWalletConfig config,
    required String password,
  }) async {
    final configJson = jsonEncode(config.toJson());
    final handle = await Isolate.run(() {
      return usingSecretArena((arena) {
        final json = decodeJsonObject(
          unwrapFfiResult(
            bindings.grin_wallet_open(
              toCStringSecret(configJson, arena),
              toCStringSecret(password, arena),
            ),
          ),
        );
        return readInt(json['handle'], 'handle');
      });
    });
    return GrinWalletClient.fromHandle(
      handle: handle,
      walletDir: config.walletDir,
      network: config.network,
    );
  }

  /// Deletes `<walletDir>/wallet_data` and everything in it. `walletDir`
  /// itself stays. A directory without a wallet counts as already deleted.
  ///
  /// This cannot delete a wallet that a client has open: close the client
  /// first. Throws [GrinWalletBusyException] if an open wallet in this
  /// process, or a closed one with a call still running, holds the
  /// directory. Nothing is deleted then, and the error is never retried.
  static Future<void> delete({required String walletDir}) => Isolate.run(() {
    usingSecretArena((arena) {
      unwrapFfiResult(
        bindings.grin_wallet_delete(toCString(walletDir, arena), 0),
      );
    });
  });

  // Instance members --------------------------------------------------------

  @override
  final String walletDir;

  @override
  final GrinNetwork network;

  final int _handle;
  final StreamController<GrinWalletEvent> _events =
      StreamController<GrinWalletEvent>.broadcast();
  bool _closed = false;
  Future<void>? _closing;

  /// The scans that were requested and have not settled, oldest first. The
  /// first one may be running; the rest wait in the queue.
  final List<_ScanRequest> _scans = [];

  /// The end of the operation queue. It never completes with an error: each
  /// caller gets its own result, and the queue only needs to know when the
  /// operation has settled.
  Future<void> _tail = Future<void>.value();

  @override
  bool get isClosed => _closed;

  @override
  Stream<GrinWalletEvent> get events => _events.stream;

  /// The native handle. For the test harness only.
  @internal
  int get nativeHandle {
    _ensureOpen();
    return _handle;
  }

  /// Runs [operation] after everything queued before it. For the test
  /// harness only.
  ///
  /// [operation] runs even if the returned future is never awaited. Its
  /// error is only observable through that future, and the queue carries on
  /// after it.
  @internal
  Future<T> runQueued<T>(Future<T> Function() operation) {
    _ensureOpen();
    return _enqueue(operation);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('GrinWalletClient is closed');
  }

  void _emit(GrinWalletEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Chains [operation] behind the previous one. A failure goes to the
  /// caller of this operation only; the queue carries on.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    // The callbacks below call a method of this client, so the pending
    // future chain refers to it. That keeps the Finalizable reachable while
    // an operation is queued or running, so the native finalizer cannot
    // close the handle under a call the caller still waits for. The queued
    // closures themselves hold only the handle, so without this a client
    // that was dropped with work queued could be collected.
    _tail = result.then<void>(
      (_) => _keepAlive(),
      onError: (Object _) => _keepAlive(),
    );
    return result;
  }

  /// Does nothing. It only gives the callbacks in [_enqueue] a reference to
  /// this client.
  void _keepAlive() {}

  @override
  Future<GrinAddressInfo> getAddress({int index = 0}) {
    _ensureOpen();
    final nativeIndex = requireU32(index, 'index');
    final handle = _handle;
    return _enqueue(() => _getAddress(handle, nativeIndex));
  }

  @override
  Future<GrinChainTip> getChainHeight() {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _getChainHeight(handle));
  }

  @override
  Future<GrinBalance> getBalance({
    bool refreshFromNode = true,
    int minimumConfirmations = 10,
  }) {
    _ensureOpen();
    final nativeConfirmations = requireU64(
      minimumConfirmations,
      'minimumConfirmations',
    );
    final handle = _handle;
    return _enqueue(
      () => _getBalance(handle, refreshFromNode, nativeConfirmations),
    );
  }

  @override
  Future<GrinScanResult> scan({
    int startHeight = 0,
    bool deleteUnconfirmed = false,
  }) {
    _ensureOpen();
    final nativeStartHeight = requireU64(startHeight, 'startHeight');
    final handle = _handle;
    final request = _ScanRequest();
    _scans.add(request);
    return _enqueue(() async {
      try {
        // The native cancel only reaches a scan that is running, so a scan
        // that was still queued when close() or cancelScan() ran must not
        // start now.
        if (_closed) {
          throw StateError('GrinWalletClient was closed before the scan ran');
        }
        if (request.cancelled) {
          throw GrinException.fromJson(
            14,
            jsonEncode({
              'code': 14,
              'message': 'scan cancelled before it started',
              'details': null,
            }),
          );
        }
        request.running = true;
        _emit(GrinScanStarted(startHeight: nativeStartHeight));
        try {
          final result = await _scan(
            handle,
            nativeStartHeight,
            deleteUnconfirmed,
          );
          _emit(GrinScanFinished(result: result));
          return result;
        } catch (error, stackTrace) {
          _emit(GrinScanFinished(error: error, stackTrace: stackTrace));
          rethrow;
        }
      } finally {
        request.repeat?.cancel();
        _scans.remove(request);
      }
    });
  }

  @override
  Future<int> lastScannedHeight() {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _lastScannedHeight(handle));
  }

  @override
  GrinScanProgress scanProgress() {
    _ensureOpen();
    return GrinScanProgress.fromJson(
      decodeJsonObject(
        unwrapFfiResult(bindings.grin_wallet_scan_progress(_handle)),
      ),
    );
  }

  @override
  void cancelScan() {
    _ensureOpen();
    final handle = _handle;
    unwrapFfiResult(bindings.grin_wallet_scan_cancel(handle));
    for (final request in _scans) {
      request.cancelled = true;
      // The native library drops a cancel that arrives before the scan has
      // started there, and a scan that has left the queue may still be on
      // its way into the library. Repeat the cancel until that scan has
      // settled. The call is cheap and takes no wallet lock, and no other
      // scan can start on this wallet before this one has returned.
      if (request.running) {
        request.repeat ??= Timer.periodic(const Duration(milliseconds: 50), (
          _,
        ) {
          try {
            unwrapFfiResult(bindings.grin_wallet_scan_cancel(handle));
          } on GrinException {
            // The scan's own future reports what happened to it.
          }
        });
      }
    }
  }

  @override
  Future<void> changePassword(String oldPassword, String newPassword) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _changePassword(handle, oldPassword, newPassword));
  }

  @override
  Future<String> getMnemonic(String password) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _getMnemonic(handle, password));
  }

  @override
  Future<void> updateNetwork({
    required String nodeUrl,
    required String? apiSecret,
    required String? socksProxy,
    required bool networkEnabled,
  }) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(
      () => _updateNetwork(
        handle,
        nodeUrl,
        apiSecret,
        socksProxy,
        networkEnabled,
      ),
    );
  }

  @override
  Future<GrinFeeEstimate> estimateFee({
    required BigInt amount,
    int minimumConfirmations = 10,
    bool selectionStrategyIsAll = false,
    bool amountIncludesFee = false,
  }) {
    _ensureOpen();
    final handle = _handle;
    final nativeAmount = amountToNative(amount);
    final nativeConfirmations = requireU64(
      minimumConfirmations,
      'minimumConfirmations',
    );
    return _enqueue(
      () => _estimateFee(
        handle,
        nativeAmount,
        nativeConfirmations,
        selectionStrategyIsAll,
        amountIncludesFee,
      ),
    );
  }

  @override
  Future<GrinTxList> getTransactions({bool refreshFromNode = true}) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _getTransactions(handle, refreshFromNode));
  }

  @override
  Future<GrinSlateInfo> decodeSlatepack(String armored, {int secretIndex = 0}) {
    _ensureOpen();
    final nativeSecretIndex = requireU32(secretIndex, 'secretIndex');
    final handle = _handle;
    final networkValue = network.value;
    return _enqueue(
      () => _decodeSlatepack(handle, networkValue, armored, nativeSecretIndex),
    );
  }

  /// Reads an unencrypted Slatepack for [network] without a wallet.
  ///
  /// An encrypted Slatepack throws [GrinSlateException], because only a
  /// wallet can decrypt it.
  static Future<GrinSlateInfo> decodeSlatepackWithoutWallet(
    String armored,
    GrinNetwork network,
  ) => _decodeSlatepack(0, network.value, armored, 0);

  @override
  Future<GrinSlatepack> initSend(GrinSendArgs args) {
    _ensureOpen();
    final handle = _handle;
    final argsJson = jsonEncode(args.toJson());
    return _enqueue(() => _initSend(handle, argsJson));
  }

  @override
  Future<GrinSendResult> sendHttp(GrinHttpSendArgs args) {
    _ensureOpen();
    final handle = _handle;
    final argsJson = jsonEncode(args.toJson());
    return _enqueue(() => _sendHttp(handle, argsJson));
  }

  @override
  Future<GrinSlatepack> receiveSlatepack(String armoredS1) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(() => _receiveSlatepack(handle, armoredS1));
  }

  @override
  Future<GrinFinalizeResult> finalizeSlatepack(
    String armoredS2, {
    bool broadcast = true,
    bool fluff = false,
  }) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(
      () => _finalizeSlatepack(handle, armoredS2, broadcast, fluff),
    );
  }

  @override
  Future<GrinSlatepack> issueInvoice(GrinInvoiceArgs args) {
    _ensureOpen();
    final handle = _handle;
    final argsJson = jsonEncode(args.toJson());
    return _enqueue(() => _issueInvoice(handle, argsJson));
  }

  @override
  Future<GrinSlatepack> processInvoice(
    String armoredI1,
    GrinProcessInvoiceArgs args,
  ) {
    _ensureOpen();
    final handle = _handle;
    final argsJson = jsonEncode(args.toJson());
    return _enqueue(() => _processInvoice(handle, armoredI1, argsJson));
  }

  @override
  Future<GrinFinalizeResult> finalizeInvoice(
    String armoredI2, {
    bool broadcast = true,
    bool fluff = false,
  }) {
    _ensureOpen();
    final handle = _handle;
    return _enqueue(
      () => _finalizeInvoice(handle, armoredI2, broadcast, fluff),
    );
  }

  @override
  Future<void> repost({int? txId, String? slateId, bool fluff = false}) {
    _ensureOpen();
    final handle = _handle;
    final nativeTxId = txIdToNative(txId);
    return _enqueue(() => _repost(handle, nativeTxId, slateId, fluff));
  }

  @override
  Future<void> cancelTransaction({int? txId, String? slateId}) {
    _ensureOpen();
    final handle = _handle;
    final nativeTxId = txIdToNative(txId);
    return _enqueue(() => _cancelTransaction(handle, nativeTxId, slateId));
  }

  @override
  Future<GrinPaymentProof> exportPaymentProof({int? txId, String? slateId}) {
    _ensureOpen();
    final handle = _handle;
    final nativeTxId = txIdToNative(txId);
    return _enqueue(() => _exportPaymentProof(handle, nativeTxId, slateId));
  }

  @override
  Future<GrinPaymentProofVerification> verifyPaymentProof(
    GrinPaymentProof proof,
  ) {
    _ensureOpen();
    final handle = _handle;
    final proofJson = proof.toJsonString();
    return _enqueue(() => _verifyPaymentProof(handle, proofJson));
  }

  /// Closes the wallet as [GrinWalletApi.close] describes. Releasing the
  /// backend's hold means detaching the native finalizer and the [events]
  /// finalizer; closing the wallet means closing the native handle.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final handle = _handle;
    // A cancel reaches only a scan that is running. A scan that left the
    // queue just before this point may not have reached the native library
    // yet, and its start clears any earlier cancel, so one cancel could be
    // lost and close() would then wait for the whole scan. Repeat it until
    // everything queued has settled; the call is cheap and takes no wallet
    // lock, and nothing new can be queued after _closed is set.
    final settled = _tail.then((_) => true);
    while (true) {
      try {
        unwrapFfiResult(bindings.grin_wallet_scan_cancel(handle));
      } on GrinException {
        // The wallet is going away either way.
      }
      final done = await Future.any<bool>([
        settled,
        Future<bool>.delayed(const Duration(milliseconds: 100), () => false),
      ]);
      if (done) break;
    }
    try {
      await _closeHandle(handle);
    } on GrinInvalidHandleException {
      // The library no longer knows the handle, so the wallet is closed
      // already and there is nothing left to release.
    } catch (_) {
      // The handle may still be open. Both finalizers stay attached, so a
      // client that is dropped now is still cleaned up, and the next
      // close() tries again instead of returning this failure for ever.
      _closing = null;
      rethrow;
    }
    _finalizer.detach(this);
    _eventsFinalizer.detach(this);
    _emit(const GrinWalletClosed());
    // Not awaited: a broadcast controller finishes closing only when every
    // subscription has received the done event, and a paused one (an
    // `await for` body that calls close(), a StreamQueue) never does.
    unawaited(_events.close());
  }

  // Isolate helpers ---------------------------------------------------------
  //
  // Each one is static, takes only numbers, booleans and strings, and builds
  // its Isolate.run closure from those alone. A closure made in an instance
  // method could drag `this` (a Finalizable with a StreamController) into
  // the message, and Isolate.run rejects that.

  static Future<GrinAddressInfo> _getAddress(int handle, int index) =>
      Isolate.run(() {
        final json = decodeJsonObject(
          unwrapFfiResult(bindings.grin_wallet_get_address(handle, index)),
        );
        return GrinAddressInfo.fromJson(json);
      });

  static Future<GrinChainTip> _getChainHeight(int handle) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(bindings.grin_wallet_get_chain_height(handle)),
    );
    return GrinChainTip.fromJson(json);
  });

  static Future<GrinBalance> _getBalance(
    int handle,
    bool refreshFromNode,
    int minConfirms,
  ) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(
        bindings.grin_wallet_get_balance(handle, refreshFromNode, minConfirms),
      ),
    );
    return GrinBalance.fromJson(json);
  });

  static Future<GrinScanResult> _scan(
    int handle,
    int startHeight,
    bool deleteUnconfirmed,
  ) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(
        bindings.grin_wallet_scan(handle, startHeight, deleteUnconfirmed),
      ),
    );
    return GrinScanResult.fromJson(json);
  });

  static Future<int> _lastScannedHeight(int handle) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(bindings.grin_wallet_get_last_scanned_height(handle)),
    );
    return readInt(json['height'], 'height');
  });

  static Future<void> _changePassword(
    int handle,
    String oldPassword,
    String newPassword,
  ) => Isolate.run(() {
    usingSecretArena((arena) {
      unwrapFfiResult(
        bindings.grin_wallet_change_password(
          handle,
          toCStringSecret(oldPassword, arena),
          toCStringSecret(newPassword, arena),
        ),
      );
    });
  });

  static Future<String> _getMnemonic(int handle, String password) =>
      Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_wallet_get_mnemonic(
                handle,
                toCStringSecret(password, arena),
              ),
            ),
          );
          return readString(json['mnemonic'], 'mnemonic');
        });
      });

  static Future<void> _updateNetwork(
    int handle,
    String nodeUrl,
    String? apiSecret,
    String? socksProxy,
    bool networkEnabled,
  ) => Isolate.run(() {
    usingSecretArena((arena) {
      unwrapFfiResult(
        bindings.grin_wallet_update_network(
          handle,
          toCString(nodeUrl, arena),
          toCStringSecretOrNull(apiSecret, arena),
          toCStringOrNull(socksProxy, arena),
          networkEnabled,
        ),
      );
    });
  });

  static Future<GrinFeeEstimate> _estimateFee(
    int handle,
    int amount,
    int minConfirms,
    bool selectionStrategyIsAll,
    bool amountIncludesFee,
  ) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(
        bindings.grin_tx_estimate_fee(
          handle,
          amount,
          minConfirms,
          selectionStrategyIsAll,
          amountIncludesFee,
        ),
      ),
    );
    return GrinFeeEstimate.fromJson(json);
  });

  static Future<GrinTxList> _getTransactions(
    int handle,
    bool refreshFromNode,
  ) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(bindings.grin_txs_get(handle, refreshFromNode)),
    );
    return GrinTxList.fromJson(json);
  });

  static Future<GrinSlateInfo> _decodeSlatepack(
    int handle,
    int networkValue,
    String armored,
    int secretIndex,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_slatepack_decode(
            handle,
            networkValue,
            toCString(armored, arena),
            secretIndex,
          ),
        ),
      );
      return GrinSlateInfo.fromJson(json);
    });
  });

  static Future<GrinSlatepack> _initSend(int handle, String argsJson) =>
      Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_tx_init_send(handle, toCString(argsJson, arena)),
            ),
          );
          return GrinSlatepack.fromJson(json);
        });
      });

  static Future<GrinSendResult> _sendHttp(int handle, String argsJson) =>
      Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_tx_send_http(handle, toCString(argsJson, arena)),
            ),
          );
          return GrinSendResult.fromJson(json);
        });
      });

  static Future<GrinSlatepack> _receiveSlatepack(
    int handle,
    String armoredS1,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_tx_receive_slatepack(
            handle,
            toCString(armoredS1, arena),
            nullptr,
          ),
        ),
      );
      return GrinSlatepack.fromJson(json);
    });
  });

  static Future<GrinFinalizeResult> _finalizeSlatepack(
    int handle,
    String armoredS2,
    bool broadcast,
    bool fluff,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_tx_finalize_slatepack(
            handle,
            toCString(armoredS2, arena),
            broadcast,
            fluff,
          ),
        ),
      );
      return GrinFinalizeResult.fromJson(json);
    });
  });

  static Future<GrinSlatepack> _issueInvoice(int handle, String argsJson) =>
      Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_tx_issue_invoice(
                handle,
                toCString(argsJson, arena),
              ),
            ),
          );
          return GrinSlatepack.fromJson(json);
        });
      });

  static Future<GrinSlatepack> _processInvoice(
    int handle,
    String armoredI1,
    String argsJson,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_tx_process_invoice(
            handle,
            toCString(armoredI1, arena),
            toCString(argsJson, arena),
          ),
        ),
      );
      return GrinSlatepack.fromJson(json);
    });
  });

  static Future<GrinFinalizeResult> _finalizeInvoice(
    int handle,
    String armoredI2,
    bool broadcast,
    bool fluff,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_tx_finalize_invoice(
            handle,
            toCString(armoredI2, arena),
            broadcast,
            fluff,
          ),
        ),
      );
      return GrinFinalizeResult.fromJson(json);
    });
  });

  static Future<void> _repost(
    int handle,
    int txId,
    String? slateId,
    bool fluff,
  ) => Isolate.run(() {
    usingSecretArena((arena) {
      unwrapFfiResult(
        bindings.grin_tx_repost(
          handle,
          txId,
          toCStringOrNull(slateId, arena),
          fluff,
        ),
      );
    });
  });

  static Future<void> _cancelTransaction(
    int handle,
    int txId,
    String? slateId,
  ) => Isolate.run(() {
    usingSecretArena((arena) {
      unwrapFfiResult(
        bindings.grin_tx_cancel(handle, txId, toCStringOrNull(slateId, arena)),
      );
    });
  });

  static Future<GrinPaymentProof> _exportPaymentProof(
    int handle,
    int txId,
    String? slateId,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_payment_proof_export(
            handle,
            txId,
            toCStringOrNull(slateId, arena),
          ),
        ),
      );
      return GrinPaymentProof.fromJson(json);
    });
  });

  static Future<GrinPaymentProofVerification> _verifyPaymentProof(
    int handle,
    String proofJson,
  ) => Isolate.run(() {
    return usingSecretArena((arena) {
      final json = decodeJsonObject(
        unwrapFfiResult(
          bindings.grin_payment_proof_verify(
            handle,
            toCString(proofJson, arena),
          ),
        ),
      );
      return GrinPaymentProofVerification.fromJson(json);
    });
  });

  static Future<void> _closeHandle(int handle) => Isolate.run(() {
    unwrapFfiResult(bindings.grin_wallet_close(handle));
  });
}

/// One call of [GrinWalletClient.scan] that has not settled.
class _ScanRequest {
  /// Set by `cancelScan`. A request that is still queued then never starts.
  bool cancelled = false;

  /// True once the request has left the queue and its scan was started.
  bool running = false;

  /// Repeats the native cancel while a cancelled scan is still running.
  Timer? repeat;
}
