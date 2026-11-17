import '../internal/json_helpers.dart';

/// What kind of destination a validated address is.
enum GrinAddressKind {
  /// A Slatepack address (`grin1...` or `tgrin1...`).
  slatepack,

  /// A v3 onion address, with or without scheme and `.onion`.
  onion,

  /// An `http://` or `https://` URL.
  http,

  /// A kind this version of the package does not know. The other fields
  /// are still read.
  unknown,
}

/// The result of validating an address for a network.
final class GrinAddressValidation {
  /// Creates a validation result.
  const GrinAddressValidation({
    required this.kind,
    required this.url,
    this.slatepackAddress,
    this.onionV3Url,
  });

  /// Reads the native `grin_address_validate` document.
  factory GrinAddressValidation.fromJson(Map<String, Object?> json) {
    final kindName = readString(json['kind'], 'kind');
    final kind = GrinAddressKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => GrinAddressKind.unknown,
    );
    return GrinAddressValidation(
      kind: kind,
      slatepackAddress: readOptionalString(
        json['slatepack_address'],
        'slatepack_address',
      ),
      onionV3Url: readOptionalString(json['onion_v3_url'], 'onion_v3_url'),
      url: readString(json['url'], 'url'),
    );
  }

  /// The kind of address that was given.
  final GrinAddressKind kind;

  /// The normalized Slatepack address. For an onion address it is derived
  /// from the onion key with the prefix of the network. Null for a URL.
  final String? slatepackAddress;

  /// `http://<label>.onion` for Slatepack and onion addresses, null for a URL.
  final String? onionV3Url;

  /// The base URL a synchronous send posts to. It never ends in `/` or
  /// `/v2/foreign`.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is GrinAddressValidation &&
      other.kind == kind &&
      other.slatepackAddress == slatepackAddress &&
      other.onionV3Url == onionV3Url &&
      other.url == url;

  @override
  int get hashCode => Object.hash(kind, slatepackAddress, onionV3Url, url);

  @override
  String toString() => 'GrinAddressValidation(${kind.name}, url: $url)';
}
