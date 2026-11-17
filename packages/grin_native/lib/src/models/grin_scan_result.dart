import '../internal/json_helpers.dart';

/// The outcome of a finished scan.
final class GrinScanResult {
  /// Creates a scan result.
  const GrinScanResult({required this.scannedHeight, required this.tipHeight});

  /// Reads the native `grin_wallet_scan` document.
  factory GrinScanResult.fromJson(Map<String, Object?> json) {
    return GrinScanResult(
      scannedHeight: readInt(json['scanned_height'], 'scanned_height'),
      tipHeight: readInt(json['tip_height'], 'tip_height'),
    );
  }

  /// The last height the scan covered.
  final int scannedHeight;

  /// The chain tip when the scan ended.
  final int tipHeight;

  @override
  bool operator ==(Object other) =>
      other is GrinScanResult &&
      other.scannedHeight == scannedHeight &&
      other.tipHeight == tipHeight;

  @override
  int get hashCode => Object.hash(scannedHeight, tipHeight);

  @override
  String toString() =>
      'GrinScanResult(scannedHeight: $scannedHeight, tipHeight: $tipHeight)';
}
