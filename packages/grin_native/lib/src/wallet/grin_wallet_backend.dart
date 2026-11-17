import '../errors/grin_exception.dart';
import '../models/grin_address_validation.dart';
import '../models/grin_mnemonic_validation.dart';
import '../models/grin_network.dart';
import '../models/grin_node_info.dart';
import '../models/grin_slate_info.dart';
import '../models/grin_wallet_config.dart';
import 'grin_wallet_api.dart';

/// The operations of a Grin backend that need no open wallet, and the way
/// to get one: [create] and [open].
///
/// A backend package provides the implementation, such as grin_native's
/// `GrinNativeBackend`. App code that takes a [GrinWalletBackend] instead of
/// calling the backend's classes directly can be tested with a fake.
abstract interface class GrinWalletBackend {
  /// Generates a new BIP39 mnemonic of [wordCount] words (12, 15, 18, 21 or
  /// 24).
  ///
  /// Throws [GrinInvalidArgumentException] for any other count, and
  /// [ArgumentError] for a count that is not between 0 and 4294967295.
  Future<String> generateMnemonic({int wordCount = 24});

  /// Checks a mnemonic. A bad phrase is a result with `valid` false, not an
  /// error.
  Future<GrinMnemonicValidation> validateMnemonic(String mnemonic);

  /// Checks [address] for [network].
  ///
  /// Accepts a Slatepack address, a v3 onion address (with or without
  /// scheme, `.onion` and `/v2/foreign`) and an `http(s)` URL. Throws
  /// [GrinInvalidAddressException] for anything else, including an address
  /// of the other network.
  Future<GrinAddressValidation> validateAddress(
    String address,
    GrinNetwork network,
  );

  /// [validateAddress] without a future.
  ///
  /// The check is stateless and fast, so it can back a synchronous
  /// validator such as Stack Wallet's
  /// `CryptoCurrency.validateAddress`. Same results and exceptions as
  /// [validateAddress].
  ///
  /// A backend that cannot answer without waiting (one that asks a remote
  /// service, say) throws [GrinNotSupportedException] here and leaves the
  /// work to [validateAddress].
  GrinAddressValidation validateAddressSync(
    String address,
    GrinNetwork network,
  );

  /// Asks a node for its version and chain tip without a wallet.
  ///
  /// It is stateless, so no wallet's [GrinWalletConfig.networkEnabled]
  /// applies to it.
  ///
  /// Throws [GrinNodeException] when it cannot be reached and
  /// [GrinInvalidArgumentException] for a bad URL or proxy.
  Future<GrinNodeInfo> testNodeConnection({
    required String nodeUrl,
    String? apiSecret,
    String? socksProxy,
  });

  /// Creates a wallet in `<config.walletDir>/wallet_data` and opens it.
  ///
  /// With a null [mnemonic] a new 24-word seed is generated; otherwise the
  /// 12 to 24 word phrase is used. Nothing contacts the node.
  ///
  /// [isNewWallet] says whether that phrase was just generated (by
  /// [generateMnemonic], for example) and so has no history on the chain.
  /// When true, the wallet is stored as needing no scan, as one created
  /// without a mnemonic is: its first refresh from the node looks only at
  /// the last 2880 blocks below the tip instead of the whole chain. Leave it
  /// false to restore a phrase that may have been used before; the first
  /// refresh then scans from the first block, or call [GrinWalletApi.scan]
  /// with a start height. Without a mnemonic it changes nothing.
  ///
  /// Throws [GrinWalletExistsException] if the directory already holds a
  /// wallet, [GrinInvalidMnemonicException] for a bad phrase and
  /// [GrinInvalidArgumentException] for a bad configuration.
  ///
  /// Throws [GrinWalletBusyException] when another wallet in this process
  /// holds the directory, or one that was closed is still finishing a call.
  /// The error is reported as it is and never retried. Close the other
  /// wallet, reuse it, or let the caller decide whether to wait.
  Future<GrinWalletApi> create({
    required GrinWalletConfig config,
    String? mnemonic,
    required String password,
    bool isNewWallet = false,
  });

  /// Opens the wallet in `<config.walletDir>/wallet_data`. Nothing contacts
  /// the node.
  ///
  /// Throws [GrinWalletNotFoundException] if there is no wallet and
  /// [GrinInvalidPasswordException] for a wrong password.
  ///
  /// A directory can be held by one wallet per process. Throws
  /// [GrinWalletBusyException] (with `walletDir`) if it is open already, or
  /// if a wallet that was closed has a call that has not returned yet. After
  /// `await wallet.close()` the directory is always free again. The error is
  /// reported as it is and never retried.
  Future<GrinWalletApi> open({
    required GrinWalletConfig config,
    required String password,
  });

  /// Deletes `<walletDir>/wallet_data` and everything in it. `walletDir`
  /// itself stays. A directory without a wallet counts as already deleted.
  ///
  /// This cannot delete a wallet that a client has open: close the client
  /// first. Throws [GrinWalletBusyException] if an open wallet in this
  /// process, or a closed one with a call still running, holds the
  /// directory. Nothing is deleted then, and the error is never retried.
  Future<void> delete({required String walletDir});

  /// Reads an unencrypted Slatepack for [network] without a wallet.
  ///
  /// An encrypted Slatepack throws [GrinSlateException], because only a
  /// wallet can decrypt it.
  Future<GrinSlateInfo> decodeSlatepackWithoutWallet(
    String armored,
    GrinNetwork network,
  );
}
