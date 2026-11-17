import 'dart:isolate';

import 'package:grin_native/codec.dart';
import 'package:grin_native/grin.dart';

import '../ffi/bindings.g.dart' as bindings;
import '../ffi/memory.dart';
import '../wallet/grin_wallet_client.dart';

/// Wallets on an in-process test chain, for tests only.
///
/// The `grin_test_*` functions exist only in a native library built with the
/// `test_utils` user-define (the workspace `pubspec.yaml` of this repository
/// sets it). Release libraries do not export them, and every method here
/// throws a [StateError] that says so when they are missing.
abstract final class GrinTestChain {
  /// Creates a wallet connected to the test chain in [chainDir], or opens it
  /// if `<walletDir>/wallet_data/wallet.seed` exists (the [mnemonic] is then
  /// ignored). The chain is started on first use of a [chainDir] and shared
  /// by every wallet created with it.
  ///
  /// [clientId] must be non-empty, unique per chain and not `node`. Reusing
  /// an id re-attaches that wallet. Every [network] is accepted, but the
  /// chain is always automated testing, so use
  /// [GrinNetwork.automatedTesting] for flows that need funds.
  ///
  /// [isNewWallet] works as in `GrinWalletClient.create` and is ignored when
  /// the wallet is opened.
  ///
  /// Like `GrinWalletClient.open`, this throws [GrinWalletBusyException] when
  /// the directory is held by another wallet in the process.
  static Future<GrinWalletClient> createWallet({
    required String chainDir,
    required String walletDir,
    required String clientId,
    GrinNetwork network = GrinNetwork.automatedTesting,
    String? mnemonic,
    required String password,
    bool isNewWallet = false,
  }) async {
    final networkValue = network.value;
    final int handle;
    try {
      handle = await Isolate.run(() {
        return usingSecretArena((arena) {
          final json = decodeJsonObject(
            unwrapFfiResult(
              bindings.grin_test_create_wallet(
                toCString(chainDir, arena),
                toCString(walletDir, arena),
                toCString(clientId, arena),
                networkValue,
                toCStringSecretOrNull(mnemonic, arena),
                toCStringSecret(password, arena),
                isNewWallet,
              ),
            ),
          );
          return readInt(json['handle'], 'handle');
        });
      });
    } on ArgumentError catch (error, stackTrace) {
      _missingSymbol(error, stackTrace);
    }
    return GrinWalletClient.fromHandle(
      handle: handle,
      walletDir: walletDir,
      network: network,
    );
  }

  /// Mines [count] blocks whose coinbase pays [wallet], and returns the
  /// chain height afterwards. Runs in the wallet's operation queue.
  ///
  /// [count] must be at least 1; a smaller value throws [ArgumentError]
  /// (the native argument is unsigned, so a negative count would mine for
  /// ever). [wallet] must come from [createWallet].
  static Future<int> mineBlocks(GrinWalletClient wallet, int count) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be at least 1');
    }
    final handle = wallet.nativeHandle;
    return wallet.runQueued(() async {
      try {
        return await _mine(handle, count);
      } on ArgumentError catch (error, stackTrace) {
        _missingSymbol(error, stackTrace);
      }
    });
  }

  // Static and primitive-only, so the Isolate.run closure cannot capture the
  // wallet (a Finalizable), which Isolate.run refuses to send.
  static Future<int> _mine(int handle, int count) => Isolate.run(() {
    final json = decodeJsonObject(
      unwrapFfiResult(bindings.grin_test_mine_blocks(handle, count)),
    );
    return readInt(json['height'], 'height');
  });

  /// Makes the native library panic, to check that a panic comes back as
  /// [GrinInternalPanicException] and does not take the process down.
  static void testPanic() {
    try {
      unwrapFfiResult(bindings.grin_test_panic());
    } on ArgumentError catch (error, stackTrace) {
      _missingSymbol(error, stackTrace);
    }
  }

  /// Rethrows [error] with its own [stackTrace], turned into a [StateError]
  /// when it is the failed lookup of a `grin_test_*` symbol.
  static Never _missingSymbol(ArgumentError error, StackTrace stackTrace) {
    // The text of the lookup failure names the missing symbol; any other
    // ArgumentError is a different problem and must not be disguised.
    if (!'${error.message}'.contains("native function 'grin_test_")) {
      Error.throwWithStackTrace(error, stackTrace);
    }
    Error.throwWithStackTrace(
      StateError(
        'The native grin library has no grin_test_* functions. Build it with '
        'the test_utils user-define (hooks.user_defines.grin_native.test_utils: '
        'true). Details: ${error.message}',
      ),
      stackTrace,
    );
  }
}
