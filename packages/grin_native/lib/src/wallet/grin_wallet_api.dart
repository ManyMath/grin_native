import '../errors/grin_exception.dart';
import '../models/grin_address_info.dart';
import '../models/grin_balance.dart';
import '../models/grin_chain_tip.dart';
import '../models/grin_fee_estimate.dart';
import '../models/grin_finalize_result.dart';
import '../models/grin_invoice_args.dart';
import '../models/grin_network.dart';
import '../models/grin_payment_proof.dart';
import '../models/grin_scan_progress.dart';
import '../models/grin_scan_result.dart';
import '../models/grin_send_args.dart';
import '../models/grin_send_result.dart';
import '../models/grin_slate_info.dart';
import '../models/grin_slatepack.dart';
import '../models/grin_tx_list.dart';
import '../models/grin_tx_log_entry.dart';
import 'grin_wallet_backend.dart';
import 'grin_wallet_event.dart';

/// One open Grin wallet, whatever backend runs it.
///
/// Get one from a [GrinWalletBackend]: `create` or `open`. grin_native's
/// `GrinWalletClient` is the implementation over the native library, and
/// the documentation here describes its behaviour, which every backend
/// should match. Code written against this interface can be tested with a
/// hand-written fake.
///
/// It is not called `GrinWallet` because that is the name of Stack Wallet's
/// own wallet class for Grin, which will hold one of these.
///
/// Operations of one wallet run one after another in the order they were
/// called; [scanProgress] and [cancelScan] are the two exceptions, because
/// they must answer while a scan runs. Amounts are `BigInt` nanogrin; see
/// `formatGrin` and `parseGrin`.
///
/// Errors reach the caller in three ways:
/// - A bad argument ([ArgumentError]: a negative or out of range number, an
///   amount that does not fit the native argument) and use after [close]
///   ([StateError]) are thrown synchronously, before a future exists. They
///   are programming errors, so they do not reach a `catchError` on the
///   returned future. The one bad argument found later is a string with
///   U+0000: it is rejected where it is converted, inside the operation, so
///   its [ArgumentError] arrives through the future.
/// - Everything the wallet library reports arrives as a [GrinException]
///   through the returned future.
/// - Library output that does not have the documented shape surfaces as a
///   [FormatException], also through the returned future. It means a
///   mismatch between the backend and its library, not a wallet problem.
///
/// While the network is turned off (`GrinWalletConfig.networkEnabled`, or
/// [updateNetwork] with `networkEnabled: false`), every operation that
/// would contact the node or send over HTTP fails at once with a
/// [GrinNodeException] whose `details['reason']` is `network_disabled`, and
/// no connection is opened. That covers [getChainHeight], [scan],
/// [estimateFee], [initSend], [sendHttp], [receiveSlatepack],
/// [issueInvoice], [processInvoice], [repost], [cancelTransaction] and
/// [verifyPaymentProof]; [getBalance] and [getTransactions] with
/// `refreshFromNode`; and [finalizeSlatepack] and [finalizeInvoice] with
/// `broadcast`. The rest work from the wallet's own data.
///
/// Call [close] when you are done.
abstract interface class GrinWalletApi {
  /// The directory the wallet was opened from, as it was given.
  String get walletDir;

  /// The chain the wallet is on.
  GrinNetwork get network;

  /// Whether [close] has been called.
  bool get isClosed;

  /// Events of this wallet. A broadcast stream: listen before the action
  /// whose events you want. It ends after [GrinWalletClosed], or without it
  /// when closing the wallet in [close] failed.
  Stream<GrinWalletEvent> get events;

  /// The address at derivation [index].
  ///
  /// Only the index 0 address can be paid to: [receiveSlatepack],
  /// [finalizeSlatepack], [processInvoice], [finalizeInvoice] and payment
  /// proofs all use index 0, so a Slatepack encrypted to any other index
  /// fails to decrypt there. Give counterparties the default address. Other
  /// indices are only useful with [decodeSlatepack]'s `secretIndex`.
  ///
  /// Throws [ArgumentError] unless [index] is between 0 and 4294967295.
  Future<GrinAddressInfo> getAddress({int index = 0});

  /// The tip of the chain according to the wallet's node.
  Future<GrinChainTip> getChainHeight();

  /// The balance.
  ///
  /// With [refreshFromNode] the wallet first updates its outputs and
  /// transactions from the node. If the node cannot be reached, the stored
  /// state comes back with `refreshedFromNode` false. While the network is
  /// turned off, [refreshFromNode] throws [GrinNodeException] instead. [minimumConfirmations]
  /// is the depth an output needs to count as spendable, and must not be
  /// negative ([ArgumentError]).
  Future<GrinBalance> getBalance({
    bool refreshFromNode = true,
    int minimumConfirmations = 10,
  });

  /// Scans the chain from [startHeight] (0 means from the first block) and
  /// repairs the wallet's outputs. Transaction history is kept. With
  /// [deleteUnconfirmed] the wallet's unconfirmed outputs are dropped and
  /// their transactions cancelled, which unlocks the inputs of a send that
  /// is still waiting for its counterparty; leave it false unless that is
  /// wanted.
  ///
  /// It can take long. Poll [scanProgress] meanwhile. [cancelScan] stops it
  /// at the end of the batch being scanned, and this call then throws
  /// [GrinCancelledException]. Emits [GrinScanStarted] and
  /// [GrinScanFinished], except for a scan that [cancelScan] stopped while
  /// it was still waiting in the queue: that one never starts and emits
  /// nothing. Throws [ArgumentError] for a negative [startHeight].
  ///
  /// The scan saves its work in batches. When it is cancelled, or fails
  /// part way (a [GrinNodeException], say), the exception's `scannedHeight`
  /// is the last height saved and the next scan can start one above it.
  /// `scannedHeight` is null when the scan did not get as far as reading
  /// the chain tip; start again from [startHeight] then.
  Future<GrinScanResult> scan({
    int startHeight = 0,
    bool deleteUnconfirmed = false,
  });

  /// The height of the last block the wallet recorded as scanned, by [scan]
  /// or by a refresh from the node, or 0 if it has never scanned.
  ///
  /// A refresh moves it too, so it does not say where a cancelled or failed
  /// [scan] stopped; the exception's `scannedHeight` does. Reads the wallet's own data and contacts no node. It
  /// runs in the queue like other operations, so during a scan it answers
  /// after the scan; use [scanProgress] for live progress.
  Future<int> lastScannedHeight();

  /// The progress of the current or most recent scan.
  ///
  /// A direct call that is not queued and takes no wallet lock, so it
  /// answers while a scan runs.
  GrinScanProgress scanProgress();

  /// Stops every [scan] that has been called and has not completed yet. A
  /// direct call that is not queued.
  ///
  /// The native scan checks for a cancel between its batches of 10,001
  /// blocks, so a running [scan] stops at the next batch boundary and its
  /// future completes with [GrinCancelledException], whose `details` carry
  /// the last saved `scanned_height`. A scan that has only just left the
  /// queue is caught as well: the cancel is repeated until that scan
  /// completes.
  ///
  /// A scan still waiting in the queue never starts. Its future completes
  /// with a [GrinCancelledException] whose `details` are null, since it
  /// scanned nothing, and it emits no events.
  ///
  /// A scan can still complete normally, or with another error such as
  /// [GrinNodeException], when it was past its last cancel check or failed
  /// before reaching one. With no scan called this does nothing, and a
  /// [scan] called afterwards runs normally.
  void cancelScan();

  /// Re-encrypts the wallet seed with [newPassword].
  ///
  /// Throws [GrinInvalidPasswordException] if [oldPassword] is wrong.
  Future<void> changePassword(String oldPassword, String newPassword);

  /// The recovery phrase, after checking [password].
  ///
  /// Throws [GrinInvalidPasswordException] if the password is wrong. The
  /// returned string cannot be wiped from memory, so keep it as briefly as
  /// you can.
  Future<String> getMnemonic(String password);

  /// Points the wallet at another node without reopening the database.
  /// Nothing contacts the node.
  ///
  /// This replaces the whole transport: [apiSecret], [socksProxy] and
  /// [networkEnabled] are required so that a caller changing only the node
  /// has to restate them. Passing null for [socksProxy] connects directly,
  /// without a proxy, and passing null for [apiSecret] sends no node API
  /// secret. With [networkEnabled] false the network is turned off as the
  /// class documentation describes; [nodeUrl] is still checked.
  ///
  /// Like every operation it runs in the queue, so it starts only after the
  /// operations before it. To apply it during a long scan, call [cancelScan]
  /// first; the scan then stops at its next batch boundary.
  Future<void> updateNetwork({
    required String nodeUrl,
    required String? apiSecret,
    required String? socksProxy,
    required bool networkEnabled,
  });

  /// Computes the fee and the inputs a send of [amount] would use, without
  /// saving or locking anything.
  ///
  /// Refreshes the wallet's outputs from the node first, then selects inputs
  /// exactly as `initSend` would. With [amountIncludesFee] the fee is taken
  /// out of [amount], otherwise it is added on top. [selectionStrategyIsAll]
  /// spends every spendable output (up to 500) instead of only as many of
  /// the smallest as needed.
  ///
  /// Throws [ArgumentError] when [amount] is negative or does not fit the
  /// native 64-bit argument (values from 2^63 up are refused, which no real
  /// balance reaches), or when [minimumConfirmations] is negative. Throws
  /// [GrinInvalidArgumentException] for an amount of
  /// 0, [GrinInsufficientFundsException] when the funds do not cover it and
  /// [GrinTransactionException] when [amountIncludesFee] and the amount is
  /// below the fee.
  Future<GrinFeeEstimate> estimateFee({
    required BigInt amount,
    int minimumConfirmations = 10,
    bool selectionStrategyIsAll = false,
    bool amountIncludesFee = false,
  });

  /// The wallet's transaction log, joined with the Slatepack and
  /// counterparty data the library keeps for each transaction.
  ///
  /// With [refreshFromNode] the outputs and transaction states are updated
  /// from the node first. If the node cannot be reached, the stored history
  /// comes back with `refreshedFromNode` false; while the network is turned
  /// off, [refreshFromNode] throws [GrinNodeException] instead. Entries are
  /// in log order.
  Future<GrinTxList> getTransactions({bool refreshFromNode = true});

  /// Reads a Slatepack with this wallet's keys, without changing anything.
  ///
  /// An encrypted Slatepack is decrypted with the wallet's address key at
  /// [secretIndex], which must be between 0 and 4294967295 ([ArgumentError]
  /// otherwise). Leading and trailing whitespace is ignored. Throws
  /// [GrinSlateException] when the text cannot be parsed or decrypted. Use
  /// [GrinWalletBackend.decodeSlatepackWithoutWallet] when no wallet is at
  /// hand.
  Future<GrinSlateInfo> decodeSlatepack(String armored, {int secretIndex = 0});

  /// Starts a send and returns the S1 Slatepack to hand to the recipient.
  ///
  /// Expects no earlier state. Locks the inputs now, unless
  /// [GrinSendArgs.lateLock] is set, so the funds are unavailable until the
  /// send is finalized or cancelled; cancel one that will not be completed
  /// with [cancelTransaction]. With [GrinSendArgs.recipientAddress] the S1 is
  /// encrypted to that address and a payment proof is requested.
  ///
  /// Throws [ArgumentError] for an amount that does not fit the native
  /// argument, [GrinInvalidArgumentException], [GrinJsonException],
  /// [GrinInvalidAddressException], [GrinInsufficientFundsException],
  /// [GrinTransactionException] or [GrinSlateException].
  Future<GrinSlatepack> initSend(GrinSendArgs args);

  /// Sends directly to the recipient's wallet over HTTP or Tor and finalizes
  /// the transaction in one call.
  ///
  /// Expects no earlier state. The inputs are locked only after the recipient
  /// has answered, so a failed exchange leaves nothing locked and nothing in
  /// the history. A target that resolves to `.onion` needs a SOCKS proxy in
  /// the wallet's network settings (see [updateNetwork]). With
  /// [GrinHttpSendArgs.post] the transaction is broadcast.
  ///
  /// The recipient's answer is checked before anything is locked: it must
  /// keep a plain kernel and the TTL this wallet set, and when a payment
  /// proof was requested it must carry one for exactly the requested
  /// address. An answer that fails those checks throws [GrinSlateException]
  /// or [GrinTransactionException] and leaves nothing in the history.
  ///
  /// A clearnet `http(s)://` target without a SOCKS proxy is reached
  /// directly, so the recipient's server learns the device's IP address.
  ///
  /// Throws [GrinHttpException] when the other wallet cannot be reached or
  /// refuses the slate, and [GrinNodeException] (with `slate_id` in its
  /// details) when the transaction was finalized but the broadcast failed;
  /// use [repost] for that one. Other errors are as for [initSend].
  Future<GrinSendResult> sendHttp(GrinHttpSendArgs args);

  /// Answers an S1 Slatepack and returns the S2 to hand back to the sender.
  ///
  /// Expects an S1, plain or encrypted to this wallet. Adds this wallet's
  /// output and signature, so a new received transaction appears in the log.
  /// When the S1 names its sender, the S2 is encrypted to it. Locks no
  /// inputs.
  ///
  /// Throws [GrinSlateException] when the text is not an S1 or cannot be
  /// decrypted, and [GrinTransactionException] when this wallet has already
  /// received it or it has expired.
  Future<GrinSlatepack> receiveSlatepack(String armoredS1);

  /// Finishes a send: takes the S2 and returns the final transaction.
  ///
  /// Expects the S2 of a send this wallet started with [initSend], whose
  /// inputs are already locked (or locks them now with
  /// [GrinSendArgs.lateLock]). With [broadcast] the transaction is posted to
  /// the node; [fluff] skips the Dandelion stem phase. Without it the
  /// transaction is stored and [repost] can broadcast it later.
  ///
  /// Throws [GrinSlateException] when the text is not an S2, or when the S2
  /// changed the kernel features or the TTL this wallet set (nothing is
  /// signed then), [GrinNotFoundException] when this wallet has no open
  /// transaction for the slate (unknown, or already finalized),
  /// [GrinTransactionException] for a bad signature, a payment proof
  /// mismatch or an expired transaction, and [GrinNodeException] (with
  /// `slate_id` in its details) when the broadcast fails after the
  /// transaction was finalized.
  Future<GrinFinalizeResult> finalizeSlatepack(
    String armoredS2, {
    bool broadcast = true,
    bool fluff = false,
  });

  /// Requests a payment: returns the I1 Slatepack to hand to the payer.
  ///
  /// Expects no earlier state. Adds a received transaction to the log at
  /// once, which [cancelTransaction] can remove if the payer never answers.
  /// Locks no inputs. With [GrinInvoiceArgs.recipientAddress] the I1 is
  /// encrypted to the payer.
  ///
  /// Throws [ArgumentError] for an amount that does not fit the native
  /// argument, [GrinInvalidArgumentException], [GrinJsonException],
  /// [GrinInvalidAddressException] or [GrinTransactionException].
  Future<GrinSlatepack> issueInvoice(GrinInvoiceArgs args);

  /// Pays an invoice: returns the I2 Slatepack to hand back to the payee.
  ///
  /// Expects an I1. Selects inputs, signs, and locks the inputs in the same
  /// call, so the funds are unavailable until the invoice is finalized or the
  /// transaction is cancelled with [cancelTransaction]. The I2 is encrypted
  /// to the payee when the I1 named one.
  ///
  /// Set [GrinProcessInvoiceArgs.expectedAmount] to the amount the user
  /// confirmed: an invoice for any other amount is then refused with
  /// [GrinTransactionException] before anything is recorded or locked.
  ///
  /// Throws [GrinSlateException] when the text is not an I1,
  /// [GrinInsufficientFundsException], and [GrinTransactionException] when
  /// the invoice was already paid or cancelled, has expired, or does not
  /// match the expected amount.
  Future<GrinSlatepack> processInvoice(
    String armoredI1,
    GrinProcessInvoiceArgs args,
  );

  /// Finishes an invoice: takes the I2 and returns the final transaction.
  ///
  /// Expects the I2 of an invoice this wallet issued with [issueInvoice].
  /// Locks nothing new (the payer's inputs were locked by [processInvoice]).
  /// [broadcast] and [fluff] work as in [finalizeSlatepack], and so do the
  /// errors, with [GrinSlateException] for anything that is not an I2 or
  /// that changed the kernel features (the payer may set a TTL).
  Future<GrinFinalizeResult> finalizeInvoice(
    String armoredI2, {
    bool broadcast = true,
    bool fluff = false,
  });

  /// Broadcasts the stored finalized transaction again.
  ///
  /// Name the transaction by [txId] (the `id` of a [GrinTxLogEntry]), by
  /// [slateId], or both; at least one is required, otherwise this throws
  /// [GrinInvalidArgumentException]. When both are given, [txId] is looked
  /// up first and [slateId] is the fallback. A negative [txId] throws
  /// [ArgumentError]; pass null to leave it out. The transaction is validated before it is posted.
  ///
  /// Only a transaction that is finalized and not yet confirmed can be
  /// reposted; never repost a confirmed one. Throws [GrinNotFoundException]
  /// when there is no such transaction, nothing is stored for it or the
  /// stored copy is not finalized, and [GrinNodeException] when the node
  /// refuses it. Changes no wallet state.
  Future<void> repost({int? txId, String? slateId, bool fluff = false});

  /// Cancels an unconfirmed sent, received or reverted transaction.
  ///
  /// Name the transaction by [txId], by [slateId], or both (both must then
  /// match the same transaction); at least one is required, otherwise this
  /// throws [GrinInvalidArgumentException]. A negative [txId] throws
  /// [ArgumentError]; pass null to leave it out. Inputs the transaction locked become spendable again and its
  /// new outputs are dropped; the log entry becomes
  /// [GrinTxType.txSentCancelled] or [GrinTxType.txReceivedCancelled].
  ///
  /// The wallet refreshes from the node first and refuses to cancel without
  /// it, so an unreachable node throws [GrinNodeException]. Throws
  /// [GrinNotFoundException] for an unknown transaction and
  /// [GrinTransactionException] when it is confirmed, a coinbase or already
  /// cancelled.
  Future<void> cancelTransaction({int? txId, String? slateId});

  /// Exports the payment proof of a finalized send that asked for one.
  ///
  /// Name the transaction by [txId], by [slateId], or both (both must then
  /// match). Uses the stored history and does not contact the node. Only the
  /// sender has a proof, and only when it passed a recipient address to
  /// [initSend]. Throws [GrinNotFoundException] when there is no such
  /// transaction, no proof, or the transaction is not finalized yet,
  /// [GrinInvalidArgumentException] when neither identifier is given and
  /// [ArgumentError] for a negative [txId].
  Future<GrinPaymentProof> exportPaymentProof({int? txId, String? slateId});

  /// Checks a payment proof and says whether this wallet is its sender or
  /// recipient.
  ///
  /// Looks up the kernel on the chain through the wallet's node and checks
  /// both signatures, then compares the addresses with this wallet's index 0
  /// address. Both flags false means the proof is valid but belongs to two
  /// other wallets. The addresses must be for the wallet's network.
  ///
  /// Throws [GrinTransactionException] when a signature does not verify or
  /// the kernel is not on the chain, [GrinJsonException] when the proof is
  /// malformed and [GrinNodeException] when the node cannot be reached.
  Future<GrinPaymentProofVerification> verifyPaymentProof(
    GrinPaymentProof proof,
  );

  /// Closes the wallet.
  ///
  /// Safe to call more than once: every call returns the same future. In
  /// order, it
  /// 1. marks the wallet closed, so new calls throw [StateError],
  /// 2. calls [cancelScan], and keeps calling it until the queue has
  ///    settled, so a running scan stops at its next batch boundary, one
  ///    that was just starting is caught too, and a scan still waiting in
  ///    the queue is skipped,
  /// 3. waits for the operations already queued, ignoring their errors,
  /// 4. releases what the backend holds for this wallet,
  /// 5. closes the wallet, emits [GrinWalletClosed] if that worked, and
  ///    then closes the [events] stream.
  ///
  /// A wallet the backend no longer knows (it was closed some other way)
  /// counts as closed, and step 5 completes as usual.
  ///
  /// If closing the wallet fails for another reason, the returned future
  /// completes with the error, nothing is emitted and the [events] stream
  /// stays open. The wallet still refuses new calls, and calling [close]
  /// again tries step 5 again.
  ///
  /// Step 3 can still take up to one scan batch (10,001 blocks and their
  /// node requests).
  ///
  /// When the returned future completes, the wallet directory is free to be
  /// opened again. The [events] stream is closed without waiting for its
  /// listeners, so a paused listener cannot stall this future.
  Future<void> close();
}
