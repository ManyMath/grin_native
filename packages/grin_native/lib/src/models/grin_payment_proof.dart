import 'dart:convert';

import '../internal/json_helpers.dart';

/// A payment proof as libwallet writes it.
///
/// It is kept as the JSON object the native library produced, so exporting a
/// proof, storing [toJsonString] and verifying it later passes the same
/// text through. The fields below are read from that object.
final class GrinPaymentProof {
  GrinPaymentProof._(
    this._json, {
    required this.amount,
    required this.excess,
    required this.recipientAddress,
    required this.senderAddress,
    required this.recipientSignature,
    required this.senderSignature,
  });

  /// Reads a proof from the `proof` object of `grin_payment_proof_export`, or
  /// from the whole `{"proof": {...}}` document.
  factory GrinPaymentProof.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> proof = json.containsKey('proof')
        ? readObject(json['proof'], 'proof')
        : json;
    return GrinPaymentProof._(
      jsonEncode(proof),
      amount: readBigInt(proof['amount'], 'amount'),
      excess: readString(proof['excess'], 'excess'),
      recipientAddress: readString(
        proof['recipient_address'],
        'recipient_address',
      ),
      senderAddress: readString(proof['sender_address'], 'sender_address'),
      recipientSignature: readString(proof['recipient_sig'], 'recipient_sig'),
      senderSignature: readString(proof['sender_sig'], 'sender_sig'),
    );
  }

  /// Reads a proof from JSON text, as [GrinPaymentProof.fromJson] does.
  factory GrinPaymentProof.fromJsonString(String text) {
    final Object? decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('expected a JSON object');
    }
    return GrinPaymentProof.fromJson(decoded);
  }

  final String _json;

  /// The amount in nanogrin. libwallet writes it as a decimal string.
  final BigInt amount;

  /// Hex of the kernel excess of the transaction.
  final String excess;

  /// The recipient's Slatepack address.
  final String recipientAddress;

  /// The sender's Slatepack address.
  final String senderAddress;

  /// The recipient's signature, 128 hex characters.
  final String recipientSignature;

  /// The sender's signature, 128 hex characters.
  final String senderSignature;

  /// The proof object as JSON text, ready to store or hand to the recipient.
  /// `verifyPaymentProof` accepts it back through [fromJsonString].
  String toJsonString() => _json;

  /// A copy of the proof object. Changing it does not change this proof.
  Map<String, Object?> toJson() => jsonDecode(_json) as Map<String, Object?>;

  /// Two proofs are equal when their six fields are. The order of the keys
  /// in the JSON they were read from does not matter, and neither does a
  /// key this class does not know.
  @override
  bool operator ==(Object other) =>
      other is GrinPaymentProof &&
      other.amount == amount &&
      other.excess == excess &&
      other.recipientAddress == recipientAddress &&
      other.senderAddress == senderAddress &&
      other.recipientSignature == recipientSignature &&
      other.senderSignature == senderSignature;

  @override
  int get hashCode => Object.hash(
    amount,
    excess,
    recipientAddress,
    senderAddress,
    recipientSignature,
    senderSignature,
  );

  @override
  String toString() =>
      'GrinPaymentProof(amount: $amount, excess: $excess, '
      'sender: $senderAddress, recipient: $recipientAddress)';
}

/// Whom a verified payment proof belongs to, from the point of view of the
/// wallet that verified it.
final class GrinPaymentProofVerification {
  /// Creates a verification result.
  const GrinPaymentProofVerification({
    required this.isSender,
    required this.isRecipient,
  });

  /// Reads the native `grin_payment_proof_verify` document.
  factory GrinPaymentProofVerification.fromJson(Map<String, Object?> json) {
    return GrinPaymentProofVerification(
      isSender: readBool(json['is_sender'], 'is_sender'),
      isRecipient: readBool(json['is_recipient'], 'is_recipient'),
    );
  }

  /// The proof's sender address is this wallet's index 0 address.
  final bool isSender;

  /// The proof's recipient address is this wallet's index 0 address.
  final bool isRecipient;

  @override
  bool operator ==(Object other) =>
      other is GrinPaymentProofVerification &&
      other.isSender == isSender &&
      other.isRecipient == isRecipient;

  @override
  int get hashCode => Object.hash(isSender, isRecipient);

  @override
  String toString() =>
      'GrinPaymentProofVerification(isSender: $isSender, '
      'isRecipient: $isRecipient)';
}
