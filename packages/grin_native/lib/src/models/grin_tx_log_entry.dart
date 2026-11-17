import '../internal/json_helpers.dart';
import 'grin_slate_state.dart';

/// The kind of a wallet transaction log entry.
enum GrinTxType {
  /// A mined block reward that has confirmed.
  confirmedCoinbase('ConfirmedCoinbase'),

  /// Funds received.
  txReceived('TxReceived'),

  /// Funds sent.
  txSent('TxSent'),

  /// A receive that was cancelled.
  txReceivedCancelled('TxReceivedCancelled'),

  /// A send that was cancelled.
  txSentCancelled('TxSentCancelled'),

  /// A transaction that a chain reorganization removed.
  txReverted('TxReverted'),

  /// A type this version of the package does not know.
  unknown('Unknown');

  const GrinTxType(this.wireName);

  /// The string used by the native library.
  final String wireName;

  /// The type named by [value]. Anything unrecognized is [unknown].
  static GrinTxType parse(String value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return unknown;
  }

  /// Whether the entry was cancelled.
  bool get isCancelled =>
      this == txSentCancelled || this == txReceivedCancelled;
}

/// The payment proof data a log entry carries. Only the sender of a
/// transaction that asked for a proof has one.
final class GrinPaymentProofSummary {
  /// Creates a payment proof summary.
  const GrinPaymentProofSummary({
    required this.receiverAddress,
    required this.senderAddress,
    required this.receiverSignaturePresent,
    required this.senderSignaturePresent,
  });

  /// Reads the `payment_proof` object of a transaction entry.
  factory GrinPaymentProofSummary.fromJson(Map<String, Object?> json) {
    return GrinPaymentProofSummary(
      receiverAddress: readString(json['receiver_address'], 'receiver_address'),
      senderAddress: readString(json['sender_address'], 'sender_address'),
      receiverSignaturePresent: readBool(
        json['receiver_signature_present'],
        'receiver_signature_present',
      ),
      senderSignaturePresent: readBool(
        json['sender_signature_present'],
        'sender_signature_present',
      ),
    );
  }

  /// The receiver's Slatepack address.
  final String receiverAddress;

  /// The sender's Slatepack address.
  final String senderAddress;

  /// Whether the receiver has signed. Both signatures are present once the
  /// transaction is finalized.
  final bool receiverSignaturePresent;

  /// Whether the sender has signed.
  final bool senderSignaturePresent;

  @override
  bool operator ==(Object other) =>
      other is GrinPaymentProofSummary &&
      other.receiverAddress == receiverAddress &&
      other.senderAddress == senderAddress &&
      other.receiverSignaturePresent == receiverSignaturePresent &&
      other.senderSignaturePresent == senderSignaturePresent;

  @override
  int get hashCode => Object.hash(
    receiverAddress,
    senderAddress,
    receiverSignaturePresent,
    senderSignaturePresent,
  );

  @override
  String toString() =>
      'GrinPaymentProofSummary(sender: $senderAddress, '
      'receiver: $receiverAddress)';
}

/// One entry of the wallet's transaction log, joined with the extra data the
/// native library keeps beside it. Amounts are in nanogrin.
final class GrinTxLogEntry {
  /// Creates a log entry.
  const GrinTxLogEntry({
    required this.id,
    required this.slateId,
    required this.slateState,
    required this.type,
    required this.creationTime,
    required this.confirmationTime,
    required this.confirmed,
    required this.confirmedHeight,
    required this.numInputs,
    required this.numOutputs,
    required this.amountCredited,
    required this.amountDebited,
    required this.fee,
    required this.ttlCutoffHeight,
    required this.kernelExcess,
    required this.kernelLookupMinHeight,
    required this.hasStoredTx,
    required this.paymentProof,
    required this.counterpartyAddress,
    required this.armoredSlatepack,
    required this.revertedAfterSecs,
  });

  /// Reads one entry of the native `grin_txs_get` document.
  factory GrinTxLogEntry.fromJson(Map<String, Object?> json) {
    final Object? slateState = json['slate_state'];
    final Object? proof = json['payment_proof'];
    return GrinTxLogEntry(
      id: readInt(json['id'], 'id'),
      slateId: readOptionalString(json['slate_id'], 'slate_id'),
      slateState: slateState == null
          ? null
          : GrinSlateState.parse(readString(slateState, 'slate_state')),
      type: GrinTxType.parse(readString(json['type'], 'type')),
      creationTime: readDateTime(json['creation_ts'], 'creation_ts'),
      confirmationTime: readOptionalDateTime(
        json['confirmation_ts'],
        'confirmation_ts',
      ),
      confirmed: readBool(json['confirmed'], 'confirmed'),
      confirmedHeight: readOptionalInt(
        json['confirmed_height'],
        'confirmed_height',
      ),
      numInputs: readInt(json['num_inputs'], 'num_inputs'),
      numOutputs: readInt(json['num_outputs'], 'num_outputs'),
      amountCredited: readBigInt(json['amount_credited'], 'amount_credited'),
      amountDebited: readBigInt(json['amount_debited'], 'amount_debited'),
      fee: readOptionalBigInt(json['fee'], 'fee'),
      ttlCutoffHeight: readOptionalInt(
        json['ttl_cutoff_height'],
        'ttl_cutoff_height',
      ),
      kernelExcess: readOptionalString(json['kernel_excess'], 'kernel_excess'),
      kernelLookupMinHeight: readOptionalInt(
        json['kernel_lookup_min_height'],
        'kernel_lookup_min_height',
      ),
      hasStoredTx: readBool(json['has_stored_tx'], 'has_stored_tx'),
      paymentProof: proof == null
          ? null
          : GrinPaymentProofSummary.fromJson(
              readObject(proof, 'payment_proof'),
            ),
      counterpartyAddress: readOptionalString(
        json['counterparty_address'],
        'counterparty_address',
      ),
      armoredSlatepack: readOptionalString(
        json['armored_slatepack'],
        'armored_slatepack',
      ),
      revertedAfterSecs: readOptionalInt(
        json['reverted_after_secs'],
        'reverted_after_secs',
      ),
    );
  }

  /// The local log id, the `txId` of `repost`, `cancelTransaction` and
  /// `exportPaymentProof`.
  final int id;

  /// The slate UUID, or null for a coinbase.
  final String? slateId;

  /// The last slate state this wallet saw, or null when there is none.
  final GrinSlateState? slateState;

  /// What kind of entry this is.
  final GrinTxType type;

  /// When the entry was created (UTC).
  final DateTime creationTime;

  /// When this wallet saw the transaction confirmed (UTC), if it did.
  final DateTime? confirmationTime;

  /// Whether the transaction is confirmed.
  final bool confirmed;

  /// The block height the transaction confirmed at, taken from the unspent
  /// outputs it created for this wallet. Null while unconfirmed, for a
  /// confirmed send that left this wallet no output (no change), and once
  /// every output it created has been spent. Null means unknown:
  /// [kernelLookupMinHeight] is only a lower bound for a kernel search, not
  /// the height the transaction confirmed at.
  final int? confirmedHeight;

  /// This wallet's inputs in the transaction.
  final int numInputs;

  /// This wallet's outputs in the transaction.
  final int numOutputs;

  /// What came in, change included.
  final BigInt amountCredited;

  /// What went out.
  final BigInt amountDebited;

  /// The fee, if known.
  final BigInt? fee;

  /// The height after which the transaction expires, if it has a limit.
  final int? ttlCutoffHeight;

  /// Hex of the kernel excess, if libwallet has recorded one.
  final String? kernelExcess;

  /// The lowest height to search for the kernel, if recorded.
  final int? kernelLookupMinHeight;

  /// Whether a finalized transaction is stored, so `repost` can broadcast it.
  final bool hasStoredTx;

  /// The payment proof data, if the transaction asked for one.
  final GrinPaymentProofSummary? paymentProof;

  /// The other party's address or URL, when the wallet knows it.
  final String? counterpartyAddress;

  /// The latest Slatepack of the transaction (S1, S2, I1, I2, or the S3 or I3
  /// written at finalization), if the wallet kept one.
  final String? armoredSlatepack;

  /// For a reverted transaction, the seconds after which it was reverted.
  final int? revertedAfterSecs;

  /// What this entry changed in the balance, in nanogrin: credited minus
  /// debited. Negative for a send.
  BigInt get netAmount => amountCredited - amountDebited;

  @override
  bool operator ==(Object other) =>
      other is GrinTxLogEntry &&
      other.id == id &&
      other.slateId == slateId &&
      other.slateState == slateState &&
      other.type == type &&
      other.creationTime == creationTime &&
      other.confirmationTime == confirmationTime &&
      other.confirmed == confirmed &&
      other.numInputs == numInputs &&
      other.numOutputs == numOutputs &&
      other.amountCredited == amountCredited &&
      other.amountDebited == amountDebited &&
      other.fee == fee &&
      other.ttlCutoffHeight == ttlCutoffHeight &&
      other.kernelExcess == kernelExcess &&
      other.confirmedHeight == confirmedHeight &&
      other.kernelLookupMinHeight == kernelLookupMinHeight &&
      other.hasStoredTx == hasStoredTx &&
      other.paymentProof == paymentProof &&
      other.counterpartyAddress == counterpartyAddress &&
      other.armoredSlatepack == armoredSlatepack &&
      other.revertedAfterSecs == revertedAfterSecs;

  @override
  int get hashCode => Object.hashAll([
    id,
    slateId,
    slateState,
    type,
    creationTime,
    confirmationTime,
    confirmed,
    numInputs,
    numOutputs,
    amountCredited,
    amountDebited,
    fee,
    ttlCutoffHeight,
    kernelExcess,
    confirmedHeight,
    kernelLookupMinHeight,
    hasStoredTx,
    paymentProof,
    counterpartyAddress,
    armoredSlatepack,
    revertedAfterSecs,
  ]);

  @override
  String toString() =>
      'GrinTxLogEntry(id: $id, slateId: $slateId, type: ${type.wireName}, '
      'state: ${slateState?.wireName}, confirmed: $confirmed, '
      'credited: $amountCredited, debited: $amountDebited, fee: $fee)';
}
