import '../internal/json_helpers.dart';
import 'grin_slate_state.dart';

/// The outcome of a send over HTTP or Tor (`sendHttp`). Amounts are in
/// nanogrin.
///
/// The exchange with the other wallet happens inside the call, so there is
/// no Slatepack to hand over.
final class GrinSendResult {
  /// Creates a send result.
  const GrinSendResult({
    required this.slateId,
    required this.state,
    required this.amount,
    required this.fee,
    required this.kernelExcess,
    required this.posted,
  });

  /// Reads the native `grin_tx_send_http` document.
  factory GrinSendResult.fromJson(Map<String, Object?> json) {
    return GrinSendResult(
      slateId: readString(json['slate_id'], 'slate_id'),
      state: GrinSlateState.parse(readString(json['state'], 'state')),
      amount: readBigInt(json['amount'], 'amount'),
      fee: readBigInt(json['fee'], 'fee'),
      kernelExcess: readString(json['kernel_excess'], 'kernel_excess'),
      posted: readBool(json['posted'], 'posted'),
    );
  }

  /// The slate UUID, lower case with hyphens.
  final String slateId;

  /// [GrinSlateState.s3].
  final GrinSlateState state;

  /// The amount sent, without the fee.
  final BigInt amount;

  /// The fee.
  final BigInt fee;

  /// Hex of the final kernel excess.
  final String kernelExcess;

  /// Whether the node accepted the transaction. False when the send was made
  /// with `post: false`.
  final bool posted;

  @override
  bool operator ==(Object other) =>
      other is GrinSendResult &&
      other.slateId == slateId &&
      other.state == state &&
      other.amount == amount &&
      other.fee == fee &&
      other.kernelExcess == kernelExcess &&
      other.posted == posted;

  @override
  int get hashCode =>
      Object.hash(slateId, state, amount, fee, kernelExcess, posted);

  @override
  String toString() =>
      'GrinSendResult(slateId: $slateId, amount: $amount, fee: $fee, '
      'posted: $posted)';
}
