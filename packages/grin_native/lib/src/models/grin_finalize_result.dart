import '../internal/json_helpers.dart';
import 'grin_slate_state.dart';

/// The outcome of finalizing a send (S3) or an invoice (I3). Amounts are in
/// nanogrin.
final class GrinFinalizeResult {
  /// Creates a finalize result.
  const GrinFinalizeResult({
    required this.slateId,
    required this.state,
    required this.amount,
    required this.fee,
    required this.kernelExcess,
    required this.posted,
    required this.armoredSlatepack,
  });

  /// Reads the native `GrinFinalized` document.
  factory GrinFinalizeResult.fromJson(Map<String, Object?> json) {
    return GrinFinalizeResult(
      slateId: readString(json['slate_id'], 'slate_id'),
      state: GrinSlateState.parse(readString(json['state'], 'state')),
      amount: readBigInt(json['amount'], 'amount'),
      fee: readBigInt(json['fee'], 'fee'),
      kernelExcess: readString(json['kernel_excess'], 'kernel_excess'),
      posted: readBool(json['posted'], 'posted'),
      armoredSlatepack: readString(
        json['armored_slatepack'],
        'armored_slatepack',
      ),
    );
  }

  /// The slate UUID, lower case with hyphens.
  final String slateId;

  /// [GrinSlateState.s3] or [GrinSlateState.i3].
  final GrinSlateState state;

  /// The amount sent or received, without the fee.
  final BigInt amount;

  /// The fee of the final transaction.
  final BigInt fee;

  /// Hex (66 characters) of the final kernel excess. A payment proof and a
  /// block explorer use it to find the transaction.
  final String kernelExcess;

  /// Whether the node accepted the transaction. False when the call was made
  /// with `broadcast: false`.
  final bool posted;

  /// The finalized slate as an unencrypted Slatepack without a sender, for
  /// reference.
  final String armoredSlatepack;

  @override
  bool operator ==(Object other) =>
      other is GrinFinalizeResult &&
      other.slateId == slateId &&
      other.state == state &&
      other.amount == amount &&
      other.fee == fee &&
      other.kernelExcess == kernelExcess &&
      other.posted == posted &&
      other.armoredSlatepack == armoredSlatepack;

  @override
  int get hashCode => Object.hash(
    slateId,
    state,
    amount,
    fee,
    kernelExcess,
    posted,
    armoredSlatepack,
  );

  @override
  String toString() =>
      'GrinFinalizeResult(slateId: $slateId, state: ${state.wireName}, '
      'amount: $amount, fee: $fee, posted: $posted)';
}
