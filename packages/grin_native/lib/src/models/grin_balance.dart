import '../internal/json_helpers.dart';

/// A wallet's balance. Amounts are in nanogrin; see `formatGrin`.
final class GrinBalance {
  /// Creates a balance.
  const GrinBalance({
    required this.lastConfirmedHeight,
    required this.minimumConfirmations,
    required this.total,
    required this.amountAwaitingFinalization,
    required this.amountAwaitingConfirmation,
    required this.amountImmature,
    required this.amountCurrentlySpendable,
    required this.amountLocked,
    required this.amountReverted,
    required this.refreshedFromNode,
  });

  /// Reads the native `grin_wallet_get_balance` document.
  factory GrinBalance.fromJson(Map<String, Object?> json) {
    return GrinBalance(
      lastConfirmedHeight: readInt(
        json['last_confirmed_height'],
        'last_confirmed_height',
      ),
      minimumConfirmations: readInt(
        json['minimum_confirmations'],
        'minimum_confirmations',
      ),
      total: readBigInt(json['total'], 'total'),
      amountAwaitingFinalization: readBigInt(
        json['amount_awaiting_finalization'],
        'amount_awaiting_finalization',
      ),
      amountAwaitingConfirmation: readBigInt(
        json['amount_awaiting_confirmation'],
        'amount_awaiting_confirmation',
      ),
      amountImmature: readBigInt(json['amount_immature'], 'amount_immature'),
      amountCurrentlySpendable: readBigInt(
        json['amount_currently_spendable'],
        'amount_currently_spendable',
      ),
      amountLocked: readBigInt(json['amount_locked'], 'amount_locked'),
      amountReverted: readBigInt(json['amount_reverted'], 'amount_reverted'),
      refreshedFromNode: readBool(
        json['refreshed_from_node'],
        'refreshed_from_node',
      ),
    );
  }

  /// The chain height the balance was computed at.
  final int lastConfirmedHeight;

  /// The confirmation depth used to decide what is spendable.
  final int minimumConfirmations;

  /// Everything the wallet holds, in every state.
  final BigInt total;

  /// Outputs of transactions waiting for the other party to finalize.
  final BigInt amountAwaitingFinalization;

  /// Outputs of transactions that are posted but not yet confirmed enough.
  final BigInt amountAwaitingConfirmation;

  /// Coinbase outputs that have not matured.
  final BigInt amountImmature;

  /// What can be spent now.
  final BigInt amountCurrentlySpendable;

  /// Outputs locked by a transaction in progress.
  final BigInt amountLocked;

  /// Outputs of transactions that were reverted by a reorganization.
  final BigInt amountReverted;

  /// False when the node could not be reached and the stored state was
  /// returned instead.
  final bool refreshedFromNode;

  /// Shorthand for [amountCurrentlySpendable].
  BigInt get spendable => amountCurrentlySpendable;

  @override
  bool operator ==(Object other) =>
      other is GrinBalance &&
      other.lastConfirmedHeight == lastConfirmedHeight &&
      other.minimumConfirmations == minimumConfirmations &&
      other.total == total &&
      other.amountAwaitingFinalization == amountAwaitingFinalization &&
      other.amountAwaitingConfirmation == amountAwaitingConfirmation &&
      other.amountImmature == amountImmature &&
      other.amountCurrentlySpendable == amountCurrentlySpendable &&
      other.amountLocked == amountLocked &&
      other.amountReverted == amountReverted &&
      other.refreshedFromNode == refreshedFromNode;

  @override
  int get hashCode => Object.hash(
    lastConfirmedHeight,
    minimumConfirmations,
    total,
    amountAwaitingFinalization,
    amountAwaitingConfirmation,
    amountImmature,
    amountCurrentlySpendable,
    amountLocked,
    amountReverted,
    refreshedFromNode,
  );

  @override
  String toString() =>
      'GrinBalance(height: $lastConfirmedHeight, total: $total, '
      'spendable: $amountCurrentlySpendable, locked: $amountLocked, '
      'immature: $amountImmature, refreshedFromNode: $refreshedFromNode)';
}
