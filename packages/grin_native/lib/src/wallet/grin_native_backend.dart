import 'package:grin_native/grin.dart';

import 'grin_wallet_client.dart';

/// The native backend as a [GrinWalletBackend]. Every method calls the
/// static member of the same name on [GrinWalletClient], so the two are
/// interchangeable; take this one where code should not depend on the
/// backend.
final class GrinNativeBackend implements GrinWalletBackend {
  /// The backend. It holds no state.
  const GrinNativeBackend();

  @override
  Future<String> generateMnemonic({int wordCount = 24}) =>
      GrinWalletClient.generateMnemonic(wordCount: wordCount);

  @override
  Future<GrinMnemonicValidation> validateMnemonic(String mnemonic) =>
      GrinWalletClient.validateMnemonic(mnemonic);

  @override
  Future<GrinAddressValidation> validateAddress(
    String address,
    GrinNetwork network,
  ) => GrinWalletClient.validateAddress(address, network);

  @override
  GrinAddressValidation validateAddressSync(
    String address,
    GrinNetwork network,
  ) => GrinWalletClient.validateAddressSync(address, network);

  @override
  Future<GrinNodeInfo> testNodeConnection({
    required String nodeUrl,
    String? apiSecret,
    String? socksProxy,
  }) => GrinWalletClient.testNodeConnection(
    nodeUrl: nodeUrl,
    apiSecret: apiSecret,
    socksProxy: socksProxy,
  );

  @override
  Future<GrinWalletClient> create({
    required GrinWalletConfig config,
    String? mnemonic,
    required String password,
    bool isNewWallet = false,
  }) => GrinWalletClient.create(
    config: config,
    mnemonic: mnemonic,
    password: password,
    isNewWallet: isNewWallet,
  );

  @override
  Future<GrinWalletClient> open({
    required GrinWalletConfig config,
    required String password,
  }) => GrinWalletClient.open(config: config, password: password);

  @override
  Future<void> delete({required String walletDir}) =>
      GrinWalletClient.delete(walletDir: walletDir);

  @override
  Future<GrinSlateInfo> decodeSlatepackWithoutWallet(
    String armored,
    GrinNetwork network,
  ) => GrinWalletClient.decodeSlatepackWithoutWallet(armored, network);
}
