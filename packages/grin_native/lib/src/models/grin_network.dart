/// The Grin chain a wallet or an address belongs to.
///
/// The numbers are the `network` values of the native library. They are our
/// own numbering and do not follow the order of `ChainTypes` in grin_core.
enum GrinNetwork {
  /// The main chain. Slatepack addresses start with `grin1`.
  mainnet(0),

  /// The public test network (Floonet). Addresses start with `tgrin1`.
  testnet(1),

  /// A private test chain with user-chosen parameters.
  userTesting(2),

  /// The chain used by automated tests, with a coinbase maturity of 3.
  automatedTesting(3);

  const GrinNetwork(this.value);

  /// The value passed to the native library.
  final int value;

  /// Whether addresses on this network use the `tgrin` prefix.
  bool get usesTestPrefix => this != mainnet;

  /// The network for a native [value], or an [ArgumentError].
  static GrinNetwork fromValue(int value) {
    for (final network in values) {
      if (network.value == value) return network;
    }
    throw ArgumentError.value(value, 'value', 'not a Grin network');
  }
}
