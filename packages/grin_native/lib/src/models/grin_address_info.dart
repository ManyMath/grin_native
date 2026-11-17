import '../internal/json_helpers.dart';

/// One of a wallet's addresses.
final class GrinAddressInfo {
  /// Creates an address record.
  const GrinAddressInfo({
    required this.slatepackAddress,
    required this.onionV3Url,
    required this.index,
  });

  /// Reads the native `grin_wallet_get_address` document.
  factory GrinAddressInfo.fromJson(Map<String, Object?> json) {
    return GrinAddressInfo(
      slatepackAddress: readString(
        json['slatepack_address'],
        'slatepack_address',
      ),
      onionV3Url: readString(json['onion_v3_url'], 'onion_v3_url'),
      index: readInt(json['index'], 'index'),
    );
  }

  /// The Slatepack address: `grin1...` on mainnet, `tgrin1...` elsewhere.
  final String slatepackAddress;

  /// The onion v3 URL of the same key, `http://<56 characters>.onion`.
  final String onionV3Url;

  /// The derivation index the address was made at.
  final int index;

  @override
  bool operator ==(Object other) =>
      other is GrinAddressInfo &&
      other.slatepackAddress == slatepackAddress &&
      other.onionV3Url == onionV3Url &&
      other.index == index;

  @override
  int get hashCode => Object.hash(slatepackAddress, onionV3Url, index);

  @override
  String toString() =>
      'GrinAddressInfo(index: $index, address: $slatepackAddress)';
}
