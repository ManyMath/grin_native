import '../internal/json_helpers.dart';

/// A snapshot of the current or most recent scan of a wallet.
final class GrinScanProgress {
  /// Creates a progress snapshot.
  const GrinScanProgress({
    required this.isScanning,
    required this.cancelRequested,
    required this.startHeight,
    required this.scannedHeight,
    required this.tipHeight,
    required this.progressPct,
  });

  /// Reads the native `grin_wallet_scan_progress` document.
  factory GrinScanProgress.fromJson(Map<String, Object?> json) {
    return GrinScanProgress(
      isScanning: readBool(json['is_scanning'], 'is_scanning'),
      cancelRequested: readBool(json['cancel_requested'], 'cancel_requested'),
      startHeight: readInt(json['start_height'], 'start_height'),
      scannedHeight: readInt(json['scanned_height'], 'scanned_height'),
      tipHeight: readInt(json['tip_height'], 'tip_height'),
      progressPct: readInt(json['progress_pct'], 'progress_pct'),
    );
  }

  /// Whether a scan is running right now.
  final bool isScanning;

  /// Whether a cancel was requested and has not been consumed yet.
  final bool cancelRequested;

  /// The height the scan started from. All heights are 0 before the first
  /// scan.
  final int startHeight;

  /// The height reached, estimated from the progress messages of the
  /// scanner. It equals [tipHeight] when the scan has finished.
  final int scannedHeight;

  /// The chain tip the scan runs to.
  final int tipHeight;

  /// Progress from 0 to 100.
  final int progressPct;

  @override
  bool operator ==(Object other) =>
      other is GrinScanProgress &&
      other.isScanning == isScanning &&
      other.cancelRequested == cancelRequested &&
      other.startHeight == startHeight &&
      other.scannedHeight == scannedHeight &&
      other.tipHeight == tipHeight &&
      other.progressPct == progressPct;

  @override
  int get hashCode => Object.hash(
    isScanning,
    cancelRequested,
    startHeight,
    scannedHeight,
    tipHeight,
    progressPct,
  );

  @override
  String toString() =>
      'GrinScanProgress(isScanning: $isScanning, $scannedHeight/$tipHeight, '
      '$progressPct%)';
}
