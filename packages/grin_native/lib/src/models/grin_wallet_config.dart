import 'grin_network.dart';

/// How to open or create a wallet: where its files are, which chain it is
/// on and which node it talks to.
///
/// This maps to the `config_json` argument of the native library.
final class GrinWalletConfig {
  /// Creates a configuration.
  ///
  /// [requestTimeout] is rounded up to whole seconds and must be positive.
  /// Leave it null for the native default of 30 seconds.
  const GrinWalletConfig({
    required this.walletDir,
    required this.network,
    required this.nodeUrl,
    this.nodeApiSecret,
    this.socksProxy,
    this.requestTimeout,
    this.networkEnabled = true,
  });

  /// The directory that holds the wallet. The files live in its `wallet_data`
  /// subdirectory and nothing else in it is touched. It must not be empty.
  ///
  /// That is grin_native's layout. A backend without a file system takes
  /// this as the name of the wallet's storage, whatever form that has; it
  /// still must not be empty, and the same string names the same wallet in
  /// `open` and `delete`.
  final String walletDir;

  /// The chain the wallet is on.
  final GrinNetwork network;

  /// The `http://` or `https://` base URL of a node's API.
  final String nodeUrl;

  /// The node's foreign API secret, or null for none.
  final String? nodeApiSecret;

  /// A SOCKS5 proxy as `host:port` with an IPv4 literal host, optionally
  /// prefixed `socks5h://` or `socks5://`, or null for a direct connection.
  /// Names are resolved by the proxy, so `.onion` nodes work through Tor.
  final String? socksProxy;

  /// The timeout of each node request, or null for the native default.
  final Duration? requestTimeout;

  /// Whether the wallet may use the network. When false, every operation
  /// that would contact the node or send over HTTP fails at once with a
  /// `GrinNodeException` whose `details['reason']` is `network_disabled`,
  /// and no connection is opened. [nodeUrl] must still be a valid URL.
  /// Change it later with `GrinWalletApi.updateNetwork`.
  final bool networkEnabled;

  /// The `config_json` document of the native library.
  Map<String, Object?> toJson() {
    final timeout = requestTimeout;
    return <String, Object?>{
      'wallet_dir': walletDir,
      'network': network.value,
      'node_url': nodeUrl,
      'node_api_secret': nodeApiSecret,
      'socks_proxy': socksProxy,
      'request_timeout_secs': timeout == null
          ? null
          : (timeout.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
                Duration.microsecondsPerSecond,
      'network_enabled': networkEnabled,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is GrinWalletConfig &&
      other.walletDir == walletDir &&
      other.network == network &&
      other.nodeUrl == nodeUrl &&
      other.nodeApiSecret == nodeApiSecret &&
      other.socksProxy == socksProxy &&
      other.requestTimeout == requestTimeout &&
      other.networkEnabled == networkEnabled;

  @override
  int get hashCode => Object.hash(
    walletDir,
    network,
    nodeUrl,
    nodeApiSecret,
    socksProxy,
    requestTimeout,
    networkEnabled,
  );

  /// Leaves out the API secret, which must not end up in logs.
  @override
  String toString() =>
      'GrinWalletConfig(walletDir: $walletDir, network: ${network.name}, '
      'nodeUrl: $nodeUrl, '
      'nodeApiSecret: ${nodeApiSecret == null ? 'none' : 'set'}, '
      'socksProxy: $socksProxy, requestTimeout: $requestTimeout, '
      'networkEnabled: $networkEnabled)';
}
