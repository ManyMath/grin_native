import '../internal/json_helpers.dart';
import 'grin_slate_state.dart';

/// What a Slatepack contains, from `decodeSlatepack`. Amounts are in
/// nanogrin.
final class GrinSlateInfo {
  /// Creates slate information.
  const GrinSlateInfo({
    required this.slateId,
    required this.state,
    required this.amount,
    required this.fee,
    required this.kernelExcess,
    required this.sender,
    required this.recipients,
    required this.ttlCutoffHeight,
    required this.numParticipants,
    required this.isEncrypted,
    required this.slateJson,
  });

  /// Reads the native `grin_slatepack_decode` document.
  factory GrinSlateInfo.fromJson(Map<String, Object?> json) {
    return GrinSlateInfo(
      slateId: readString(json['slate_id'], 'slate_id'),
      state: GrinSlateState.parse(readString(json['state'], 'state')),
      amount: readBigInt(json['amount'], 'amount'),
      fee: readBigInt(json['fee'], 'fee'),
      kernelExcess: readOptionalString(json['kernel_excess'], 'kernel_excess'),
      sender: readOptionalString(json['sender'], 'sender'),
      recipients: readStringList(json['recipients'], 'recipients'),
      ttlCutoffHeight: readOptionalInt(
        json['ttl_cutoff_height'],
        'ttl_cutoff_height',
      ),
      numParticipants: readInt(json['num_participants'], 'num_participants'),
      isEncrypted: readBool(json['is_encrypted'], 'is_encrypted'),
      slateJson: readString(json['slate_json'], 'slate_json'),
    );
  }

  /// The slate UUID, lower case with hyphens.
  final String slateId;

  /// The slate's state, or [GrinSlateState.unknown] for a pre-V4 slate.
  final GrinSlateState state;

  /// The amount the slate carries. It is 0 on S2, S3, I2 and I3, which
  /// libwallet clears on the return journey.
  final BigInt amount;

  /// The fee the slate carries. 0 on S2 and I1.
  final BigInt fee;

  /// Hex of the final kernel excess. Only S3 and I3 have one.
  final String? kernelExcess;

  /// The sender address in the Slatepack, inside the encryption when there is
  /// one.
  final String? sender;

  /// The recipient list from the encrypted metadata. libwallet does not
  /// write one, so this is normally empty; use [isEncrypted] to tell whether
  /// the payload was encrypted.
  final List<String> recipients;

  /// The height after which the transaction expires, if it has a limit.
  final int? ttlCutoffHeight;

  /// How many participants the slate has.
  final int numParticipants;

  /// Whether the payload was encrypted.
  final bool isEncrypted;

  /// The slate as V4 JSON text.
  final String slateJson;

  @override
  bool operator ==(Object other) =>
      other is GrinSlateInfo &&
      other.slateId == slateId &&
      other.state == state &&
      other.amount == amount &&
      other.fee == fee &&
      other.kernelExcess == kernelExcess &&
      other.sender == sender &&
      listsEqual(other.recipients, recipients) &&
      other.ttlCutoffHeight == ttlCutoffHeight &&
      other.numParticipants == numParticipants &&
      other.isEncrypted == isEncrypted &&
      other.slateJson == slateJson;

  @override
  int get hashCode => Object.hash(
    slateId,
    state,
    amount,
    fee,
    kernelExcess,
    sender,
    Object.hashAll(recipients),
    ttlCutoffHeight,
    numParticipants,
    isEncrypted,
    slateJson,
  );

  @override
  String toString() =>
      'GrinSlateInfo(slateId: $slateId, state: ${state.wireName}, '
      'amount: $amount, fee: $fee, isEncrypted: $isEncrypted)';
}
