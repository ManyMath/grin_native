import '../internal/json_helpers.dart';

/// The fee and inputs a send would use, from `estimateFee`. Amounts are in
/// nanogrin.
final class GrinFeeEstimate {
  /// Creates a fee estimate.
  const GrinFeeEstimate({
    required this.fee,
    required this.amount,
    required this.netAmount,
    required this.total,
    required this.inputsCount,
    required this.changeOutputs,
  });

  /// Reads the native `grin_tx_estimate_fee` document.
  factory GrinFeeEstimate.fromJson(Map<String, Object?> json) {
    return GrinFeeEstimate(
      fee: readBigInt(json['fee'], 'fee'),
      amount: readBigInt(json['amount'], 'amount'),
      netAmount: readBigInt(json['net_amount'], 'net_amount'),
      total: readBigInt(json['total'], 'total'),
      inputsCount: readInt(json['inputs_count'], 'inputs_count'),
      changeOutputs: readInt(json['change_outputs'], 'change_outputs'),
    );
  }

  /// The fee.
  final BigInt fee;

  /// The net amount the recipient gets.
  final BigInt amount;

  /// The same as [amount].
  final BigInt netAmount;

  /// [amount] plus [fee]: what leaves the wallet apart from change.
  final BigInt total;

  /// How many outputs the send would spend.
  final int inputsCount;

  /// 0 when the inputs add up exactly, otherwise 1.
  final int changeOutputs;

  @override
  bool operator ==(Object other) =>
      other is GrinFeeEstimate &&
      other.fee == fee &&
      other.amount == amount &&
      other.netAmount == netAmount &&
      other.total == total &&
      other.inputsCount == inputsCount &&
      other.changeOutputs == changeOutputs;

  @override
  int get hashCode =>
      Object.hash(fee, amount, netAmount, total, inputsCount, changeOutputs);

  @override
  String toString() =>
      'GrinFeeEstimate(fee: $fee, amount: $amount, total: $total, '
      'inputsCount: $inputsCount, changeOutputs: $changeOutputs)';
}
