import '../internal/json_helpers.dart';
import 'grin_slate_state.dart';

/// A Slatepack this wallet produced, to hand to the other party.
///
/// Returned for the S1, S2, I1 and I2 steps. Amounts are in nanogrin.
final class GrinSlatepack {
  /// Creates a Slatepack result.
  const GrinSlatepack({
    required this.slateId,
    required this.state,
    required this.armoredSlatepack,
    required this.amount,
    required this.fee,
    required this.sender,
    required this.recipients,
    required this.isEncrypted,
  });

  /// Reads the native `GrinSlatepack` document.
  factory GrinSlatepack.fromJson(Map<String, Object?> json) {
    return GrinSlatepack(
      slateId: readString(json['slate_id'], 'slate_id'),
      state: GrinSlateState.parse(readString(json['state'], 'state')),
      armoredSlatepack: readString(
        json['armored_slatepack'],
        'armored_slatepack',
      ),
      amount: readBigInt(json['amount'], 'amount'),
      fee: readBigInt(json['fee'], 'fee'),
      sender: readString(json['sender'], 'sender'),
      recipients: readStringList(json['recipients'], 'recipients'),
      isEncrypted: readBool(json['is_encrypted'], 'is_encrypted'),
    );
  }

  /// The slate UUID, lower case with hyphens.
  final String slateId;

  /// [GrinSlateState.s1], [GrinSlateState.s2], [GrinSlateState.i1] or
  /// [GrinSlateState.i2].
  final GrinSlateState state;

  /// The text to give to the other party.
  final String armoredSlatepack;

  /// What the transaction moves. S2 and I2 report the amount of the S1 or
  /// I1 they answer.
  final BigInt amount;

  /// The fee. 0 on I1, because the payer sets it.
  final BigInt fee;

  /// This wallet's index 0 address, embedded in the Slatepack.
  final String sender;

  /// The addresses the Slatepack is encrypted to, empty when it is not.
  final List<String> recipients;

  /// Whether the Slatepack is encrypted.
  final bool isEncrypted;

  @override
  bool operator ==(Object other) =>
      other is GrinSlatepack &&
      other.slateId == slateId &&
      other.state == state &&
      other.armoredSlatepack == armoredSlatepack &&
      other.amount == amount &&
      other.fee == fee &&
      other.sender == sender &&
      listsEqual(other.recipients, recipients) &&
      other.isEncrypted == isEncrypted;

  @override
  int get hashCode => Object.hash(
    slateId,
    state,
    armoredSlatepack,
    amount,
    fee,
    sender,
    Object.hashAll(recipients),
    isEncrypted,
  );

  @override
  String toString() =>
      'GrinSlatepack(slateId: $slateId, state: ${state.wireName}, '
      'amount: $amount, fee: $fee, isEncrypted: $isEncrypted)';
}
