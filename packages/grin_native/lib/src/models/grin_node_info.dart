import '../internal/json_helpers.dart';

/// The answer of a node to a connection test.
final class GrinNodeInfo {
  /// Creates a node info record.
  const GrinNodeInfo({
    required this.nodeVersion,
    required this.blockHeaderVersion,
    required this.height,
    required this.hash,
  });

  /// Reads the native `grin_node_test_connection` document.
  factory GrinNodeInfo.fromJson(Map<String, Object?> json) {
    return GrinNodeInfo(
      nodeVersion: readString(json['node_version'], 'node_version'),
      blockHeaderVersion: readInt(
        json['block_header_version'],
        'block_header_version',
      ),
      height: readInt(json['height'], 'height'),
      hash: readString(json['hash'], 'hash'),
    );
  }

  /// The node software version.
  final String nodeVersion;

  /// The block header version the node currently accepts.
  final int blockHeaderVersion;

  /// The height of the node's chain tip.
  final int height;

  /// The hash of the tip block.
  final String hash;

  @override
  bool operator ==(Object other) =>
      other is GrinNodeInfo &&
      other.nodeVersion == nodeVersion &&
      other.blockHeaderVersion == blockHeaderVersion &&
      other.height == height &&
      other.hash == hash;

  @override
  int get hashCode =>
      Object.hash(nodeVersion, blockHeaderVersion, height, hash);

  @override
  String toString() =>
      'GrinNodeInfo(version: $nodeVersion, height: $height, hash: $hash)';
}
