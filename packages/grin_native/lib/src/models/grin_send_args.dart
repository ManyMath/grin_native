import '../internal/json_helpers.dart';

/// Arguments of `initSend`: a send that is completed by passing Slatepacks.
///
/// Amounts are in nanogrin and must fit the native 64-bit argument;
/// [toJson] throws [ArgumentError] for one that does not.
final class GrinSendArgs {
  /// Creates send arguments.
  const GrinSendArgs({
    required this.amount,
    this.minimumConfirmations = 10,
    this.selectionStrategyIsAll = false,
    this.amountIncludesFee = false,
    this.recipientAddress,
    this.ttlBlocks,
    this.message,
    this.lateLock = false,
  });

  /// The amount to send. Must be greater than 0.
  final BigInt amount;

  /// The confirmations an output needs to be spent.
  final int minimumConfirmations;

  /// True spends all spendable outputs (up to 500), false only as many of the
  /// smallest as needed.
  final bool selectionStrategyIsAll;

  /// True takes the fee out of [amount]; false adds it on top.
  final bool amountIncludesFee;

  /// The recipient's Slatepack address. When given, the S1 is encrypted to it
  /// and a payment proof is requested from it.
  final String? recipientAddress;

  /// Blocks until the transaction expires, 1 to 1,000,000,000, or null for
  /// no limit.
  final int? ttlBlocks;

  /// Accepted and ignored by the native library, because Slate V4 has no
  /// message field.
  final String? message;

  /// True selects and locks the inputs at finalization instead of now.
  final bool lateLock;

  /// The `args_json` of `grin_tx_init_send`.
  Map<String, Object?> toJson() => <String, Object?>{
    'amount': amountToNative(amount),
    'min_confirms': minimumConfirmations,
    'selection_strategy_is_all': selectionStrategyIsAll,
    'amount_includes_fee': amountIncludesFee,
    'recipient_address': recipientAddress,
    'ttl_blocks': ttlBlocks,
    'message': message,
    'late_lock': lateLock,
  };

  @override
  bool operator ==(Object other) =>
      other is GrinSendArgs &&
      other.amount == amount &&
      other.minimumConfirmations == minimumConfirmations &&
      other.selectionStrategyIsAll == selectionStrategyIsAll &&
      other.amountIncludesFee == amountIncludesFee &&
      other.recipientAddress == recipientAddress &&
      other.ttlBlocks == ttlBlocks &&
      other.message == message &&
      other.lateLock == lateLock;

  @override
  int get hashCode => Object.hash(
    amount,
    minimumConfirmations,
    selectionStrategyIsAll,
    amountIncludesFee,
    recipientAddress,
    ttlBlocks,
    message,
    lateLock,
  );

  @override
  String toString() =>
      'GrinSendArgs(amount: $amount, '
      'minimumConfirmations: $minimumConfirmations, '
      'recipientAddress: $recipientAddress)';
}

/// Arguments of `sendHttp`: a send that talks to the recipient's wallet
/// directly, over HTTP or Tor.
///
/// It takes every field of [GrinSendArgs] and adds the target and the
/// broadcast options.
final class GrinHttpSendArgs {
  /// Creates arguments for an HTTP send.
  const GrinHttpSendArgs({
    required this.amount,
    required this.recipientUrlOrAddress,
    this.minimumConfirmations = 10,
    this.selectionStrategyIsAll = false,
    this.amountIncludesFee = false,
    this.recipientAddress,
    this.ttlBlocks,
    this.message,
    this.lateLock = false,
    this.fluff = false,
    this.post = true,
  });

  /// The amount to send. Must be greater than 0.
  final BigInt amount;

  /// A Slatepack address, a v3 onion address or an `http(s)://` URL. An
  /// address that resolves to `.onion` needs a SOCKS proxy in the wallet's
  /// network settings. An `http(s)://` URL is reached directly when the
  /// wallet has no proxy, which shows the device's IP address to that
  /// server; with a proxy every target goes through it.
  final String recipientUrlOrAddress;

  /// The confirmations an output needs to be spent.
  final int minimumConfirmations;

  /// True spends all spendable outputs (up to 500), false only as many of the
  /// smallest as needed.
  final bool selectionStrategyIsAll;

  /// True takes the fee out of [amount]; false adds it on top.
  final bool amountIncludesFee;

  /// The recipient's Slatepack address, to request a payment proof when
  /// [recipientUrlOrAddress] is an onion address or a URL. It must match
  /// [recipientUrlOrAddress] when that is a Slatepack address too.
  final String? recipientAddress;

  /// Blocks until the transaction expires, 1 to 1,000,000,000, or null for
  /// no limit.
  final int? ttlBlocks;

  /// Accepted and ignored by the native library.
  final String? message;

  /// True selects and locks the inputs at finalization instead of now.
  final bool lateLock;

  /// Broadcast without the Dandelion stem phase.
  final bool fluff;

  /// Broadcast after finalizing. False leaves the finalized transaction in
  /// the wallet for `repost`.
  final bool post;

  /// The `args_json` of `grin_tx_send_http`.
  Map<String, Object?> toJson() => <String, Object?>{
    'amount': amountToNative(amount),
    'min_confirms': minimumConfirmations,
    'selection_strategy_is_all': selectionStrategyIsAll,
    'amount_includes_fee': amountIncludesFee,
    'recipient_address': recipientAddress,
    'ttl_blocks': ttlBlocks,
    'message': message,
    'late_lock': lateLock,
    'recipient_url_or_address': recipientUrlOrAddress,
    'fluff': fluff,
    'post': post,
  };

  @override
  bool operator ==(Object other) =>
      other is GrinHttpSendArgs &&
      other.amount == amount &&
      other.recipientUrlOrAddress == recipientUrlOrAddress &&
      other.minimumConfirmations == minimumConfirmations &&
      other.selectionStrategyIsAll == selectionStrategyIsAll &&
      other.amountIncludesFee == amountIncludesFee &&
      other.recipientAddress == recipientAddress &&
      other.ttlBlocks == ttlBlocks &&
      other.message == message &&
      other.lateLock == lateLock &&
      other.fluff == fluff &&
      other.post == post;

  @override
  int get hashCode => Object.hash(
    amount,
    recipientUrlOrAddress,
    minimumConfirmations,
    selectionStrategyIsAll,
    amountIncludesFee,
    recipientAddress,
    ttlBlocks,
    message,
    lateLock,
    fluff,
    post,
  );

  @override
  String toString() =>
      'GrinHttpSendArgs(amount: $amount, '
      'recipientUrlOrAddress: $recipientUrlOrAddress, post: $post)';
}
