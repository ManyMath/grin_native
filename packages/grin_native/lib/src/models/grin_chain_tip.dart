import '../internal/json_helpers.dart';

/// The tip of the chain as the wallet's node reports it.
final class GrinChainTip {
  /// Creates a chain tip.
  const GrinChainTip({required this.height, required this.hash});

  /// Reads the native `grin_wallet_get_chain_height` document.
  factory GrinChainTip.fromJson(Map<String, Object?> json) {
    return GrinChainTip(
      height: readInt(json['height'], 'height'),
      hash: readString(json['hash'], 'hash'),
    );
  }

  /// The height of the tip block.
  final int height;

  /// The hash of the tip block.
  final String hash;

  @override
  bool operator ==(Object other) =>
      other is GrinChainTip && other.height == height && other.hash == hash;

  @override
  int get hashCode => Object.hash(height, hash);

  @override
  String toString() => 'GrinChainTip(height: $height, hash: $hash)';
}
