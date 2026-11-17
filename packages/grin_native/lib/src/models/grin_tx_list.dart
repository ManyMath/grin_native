import '../internal/json_helpers.dart';
import 'grin_tx_log_entry.dart';

/// The wallet's transaction log, from `getTransactions`.
final class GrinTxList {
  /// Creates a transaction list.
  const GrinTxList({
    required this.refreshedFromNode,
    required this.transactions,
  });

  /// Reads the native `grin_txs_get` document.
  factory GrinTxList.fromJson(Map<String, Object?> json) {
    final Object? txs = json['txs'];
    if (txs is! List<Object?>) {
      throw FormatException('"txs" is not an array', txs);
    }
    return GrinTxList(
      refreshedFromNode: readBool(
        json['refreshed_from_node'],
        'refreshed_from_node',
      ),
      transactions: List<GrinTxLogEntry>.unmodifiable(
        txs.map(
          (Object? item) => GrinTxLogEntry.fromJson(readObject(item, 'txs[]')),
        ),
      ),
    );
  }

  /// False when the node could not be reached and the stored history was
  /// returned instead.
  final bool refreshedFromNode;

  /// The entries in log order.
  final List<GrinTxLogEntry> transactions;

  /// The entry with the slate id [slateId], or null.
  GrinTxLogEntry? bySlateId(String slateId) {
    for (final entry in transactions) {
      if (entry.slateId == slateId) return entry;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is GrinTxList &&
      other.refreshedFromNode == refreshedFromNode &&
      listsEqual(other.transactions, transactions);

  @override
  int get hashCode =>
      Object.hash(refreshedFromNode, Object.hashAll(transactions));

  @override
  String toString() =>
      'GrinTxList(${transactions.length} entries, '
      'refreshedFromNode: $refreshedFromNode)';
}
