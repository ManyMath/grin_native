import '../internal/json_helpers.dart';

/// Arguments of `issueInvoice`: a request for payment that the payer
/// answers with a Slatepack.
///
/// The amount is in nanogrin and must fit the native 64-bit argument;
/// [toJson] throws [ArgumentError] for one that does not.
final class GrinInvoiceArgs {
  /// Creates invoice arguments.
  const GrinInvoiceArgs({
    required this.amount,
    this.destinationAccountName,
    this.recipientAddress,
  });

  /// The amount to request. Must be greater than 0.
  final BigInt amount;

  /// The wallet account that receives the payment. An unknown name falls
  /// back to the default account.
  final String? destinationAccountName;

  /// The payer's Slatepack address. When given, the I1 is encrypted to it.
  final String? recipientAddress;

  /// The `args_json` of `grin_tx_issue_invoice`.
  Map<String, Object?> toJson() => <String, Object?>{
    'amount': amountToNative(amount),
    'dest_acct_name': destinationAccountName,
    'recipient_address': recipientAddress,
  };

  @override
  bool operator ==(Object other) =>
      other is GrinInvoiceArgs &&
      other.amount == amount &&
      other.destinationAccountName == destinationAccountName &&
      other.recipientAddress == recipientAddress;

  @override
  int get hashCode =>
      Object.hash(amount, destinationAccountName, recipientAddress);

  @override
  String toString() =>
      'GrinInvoiceArgs(amount: $amount, recipientAddress: $recipientAddress)';
}

/// Arguments of `processInvoice`: how to pay an invoice.
final class GrinProcessInvoiceArgs {
  /// Creates arguments for paying an invoice.
  const GrinProcessInvoiceArgs({
    this.minimumConfirmations = 10,
    this.selectionStrategyIsAll = false,
    this.ttlBlocks,
    this.expectedAmount,
  });

  /// The confirmations an output needs to be spent.
  final int minimumConfirmations;

  /// True spends all spendable outputs (up to 500), false only as many of the
  /// smallest as needed.
  final bool selectionStrategyIsAll;

  /// Blocks until the transaction expires, 1 to 1,000,000,000, or null for
  /// no limit.
  final int? ttlBlocks;

  /// The amount in nanogrin the payer agreed to pay, or null for no check.
  /// When set and the invoice asks for any other amount, `processInvoice`
  /// throws `GrinTransactionException` (with `invoice_amount` and
  /// `expected_amount` in its details) and nothing is recorded or locked.
  /// Must fit the native 64-bit argument; [toJson] throws [ArgumentError]
  /// for one that does not.
  final BigInt? expectedAmount;

  /// The `args_json` of `grin_tx_process_invoice`.
  Map<String, Object?> toJson() {
    final expected = expectedAmount;
    return <String, Object?>{
      'min_confirms': minimumConfirmations,
      'selection_strategy_is_all': selectionStrategyIsAll,
      'ttl_blocks': ttlBlocks,
      'expected_amount': expected == null
          ? null
          : amountToNative(expected, 'expectedAmount'),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is GrinProcessInvoiceArgs &&
      other.minimumConfirmations == minimumConfirmations &&
      other.selectionStrategyIsAll == selectionStrategyIsAll &&
      other.ttlBlocks == ttlBlocks &&
      other.expectedAmount == expectedAmount;

  @override
  int get hashCode => Object.hash(
    minimumConfirmations,
    selectionStrategyIsAll,
    ttlBlocks,
    expectedAmount,
  );

  @override
  String toString() =>
      'GrinProcessInvoiceArgs(minimumConfirmations: $minimumConfirmations, '
      'selectionStrategyIsAll: $selectionStrategyIsAll, '
      'expectedAmount: $expectedAmount)';
}
