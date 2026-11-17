import 'dart:io';

import 'package:grin_native/grin_native.dart';
import 'package:grin_native/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// Block reward on the test chain: 60 grin.
final BigInt reward = BigInt.from(60000000000);
final BigInt grin = BigInt.from(1000000000);

/// Alice and Bob on a fresh chain in a temporary directory, with [blocks]
/// mined to Alice. Coinbase maturity on this chain is 3, so with 5 blocks
/// the rewards of heights 1 and 2 are spendable at one confirmation.
class Wallets {
  Wallets(this.alice, this.bob, this.aliceAddress, this.bobAddress);

  final GrinWalletClient alice;
  final GrinWalletClient bob;
  final String aliceAddress;
  final String bobAddress;
}

Future<Wallets> setUpWallets({int blocks = 5}) async {
  final root = await makeTempDir('grin_slatepack_');
  final chainDir = Directory(p.join(root.path, 'chain'))..createSync();

  Future<GrinWalletClient> wallet(String id) async {
    final dir = Directory(p.join(root.path, id))..createSync();
    final client = await GrinTestChain.createWallet(
      chainDir: chainDir.path,
      walletDir: dir.path,
      clientId: id,
      password: 'pw',
    );
    addTearDown(client.close);
    return client;
  }

  final alice = await wallet('alice');
  final bob = await wallet('bob');
  if (blocks > 0) await GrinTestChain.mineBlocks(alice, blocks);
  return Wallets(
    alice,
    bob,
    (await alice.getAddress()).slatepackAddress,
    (await bob.getAddress()).slatepackAddress,
  );
}

Future<GrinBalance> balanceOf(GrinWalletClient wallet, {bool refresh = true}) =>
    wallet.getBalance(refreshFromNode: refresh, minimumConfirmations: 1);

Future<GrinTxLogEntry> entryFor(
  GrinWalletClient wallet,
  String slateId, {
  bool refresh = false,
}) async {
  final list = await wallet.getTransactions(refreshFromNode: refresh);
  final matches = list.transactions.where((e) => e.slateId == slateId);
  expect(matches, hasLength(1), reason: 'entries for $slateId');
  return matches.single;
}

void main() {
  test('S1 -> S2 -> S3 with a payment proof', () async {
    final w = await setUpWallets();
    final amount = BigInt.from(50) * grin;

    // Heights 1 and 2 are mature at height 5.
    final start = await balanceOf(w.alice);
    expect(start.spendable, reward * BigInt.two);

    final estimate = await w.alice.estimateFee(
      amount: amount,
      minimumConfirmations: 1,
    );
    final fee = estimate.fee;
    expect(fee, greaterThan(BigInt.zero));
    expect(estimate.amount, amount);
    expect(estimate.netAmount, amount);
    expect(estimate.total, amount + fee);
    expect(estimate.inputsCount, 1);
    expect(estimate.changeOutputs, 1);
    final inclusive = await w.alice.estimateFee(
      amount: amount,
      minimumConfirmations: 1,
      amountIncludesFee: true,
    );
    expect(inclusive.total, amount);
    expect(inclusive.amount + inclusive.fee, amount);

    // The estimate saves and locks nothing.
    expect(
      (await balanceOf(w.alice, refresh: false)).amountLocked,
      BigInt.zero,
    );

    final s1 = await w.alice.initSend(
      GrinSendArgs(
        amount: amount,
        minimumConfirmations: 1,
        recipientAddress: w.bobAddress,
        message: 'unused',
      ),
    );
    expect(s1.state, GrinSlateState.s1);
    expect(s1.isEncrypted, isTrue);
    expect(s1.sender, w.aliceAddress);
    expect(s1.recipients, [w.bobAddress]);
    expect(s1.amount, amount);
    expect(s1.fee, fee);
    expect(s1.armoredSlatepack, startsWith('BEGINSLATEPACK.'));
    final slateId = s1.slateId;

    // Only Bob can read it.
    await expectLater(
      GrinWalletClient.decodeSlatepackWithoutWallet(
        s1.armoredSlatepack,
        GrinNetwork.automatedTesting,
      ),
      throwsA(isA<GrinSlateException>()),
    );
    await expectLater(
      w.alice.decodeSlatepack(s1.armoredSlatepack),
      throwsA(isA<GrinSlateException>()),
    );
    final decoded = await w.bob.decodeSlatepack(s1.armoredSlatepack);
    expect(decoded.slateId, slateId);
    expect(decoded.state, GrinSlateState.s1);
    expect(decoded.isEncrypted, isTrue);
    expect(decoded.sender, w.aliceAddress);
    expect(decoded.amount, amount);
    expect(decoded.fee, fee);
    expect(decoded.numParticipants, 2);
    expect(decoded.kernelExcess, isNull);
    expect(decoded.slateJson, contains(slateId));

    // Alice's side: locked, logged, proof requested, nothing stored to post.
    final sent = await entryFor(w.alice, slateId);
    expect(sent.type, GrinTxType.txSent);
    expect(sent.slateState, GrinSlateState.s1);
    expect(sent.numInputs, estimate.inputsCount);
    expect(sent.counterpartyAddress, w.bobAddress);
    expect(sent.armoredSlatepack, s1.armoredSlatepack);
    expect(sent.paymentProof?.receiverAddress, w.bobAddress);
    expect(sent.paymentProof?.senderAddress, w.aliceAddress);
    expect(sent.hasStoredTx, isFalse);
    expect(
      (await balanceOf(w.alice, refresh: false)).amountLocked,
      greaterThan(BigInt.zero),
    );

    final s2 = await w.bob.receiveSlatepack(s1.armoredSlatepack);
    expect(s2.state, GrinSlateState.s2);
    expect(s2.slateId, slateId);
    expect(s2.isEncrypted, isTrue);
    expect(s2.sender, w.bobAddress);
    expect(s2.recipients, [w.aliceAddress]);
    expect(s2.amount, amount);
    expect(s2.fee, fee);
    // Receiving twice is refused.
    await expectLater(
      w.bob.receiveSlatepack(s1.armoredSlatepack),
      throwsA(isA<GrinTransactionException>()),
    );

    final readS2 = await w.alice.decodeSlatepack(s2.armoredSlatepack);
    expect(readS2.state, GrinSlateState.s2);
    expect(readS2.slateId, slateId);
    expect(readS2.sender, w.bobAddress);

    final s3 = await w.alice.finalizeSlatepack(
      s2.armoredSlatepack,
      broadcast: true,
    );
    expect(s3.state, GrinSlateState.s3);
    expect(s3.slateId, slateId);
    expect(s3.posted, isTrue);
    expect(s3.amount, amount);
    expect(s3.fee, fee);
    expect(s3.kernelExcess, hasLength(66));
    // The transaction context is gone once finalized.
    await expectLater(
      w.alice.finalizeSlatepack(s2.armoredSlatepack, broadcast: false),
      throwsA(isA<GrinNotFoundException>()),
    );

    // The broadcast mined height 6; one more block confirms it further.
    expect(await GrinTestChain.mineBlocks(w.alice, 1), 7);

    final finalInfo = await GrinWalletClient.decodeSlatepackWithoutWallet(
      s3.armoredSlatepack,
      GrinNetwork.automatedTesting,
    );
    expect(finalInfo.state, GrinSlateState.s3);
    expect(finalInfo.isEncrypted, isFalse);
    expect(finalInfo.sender, isNull);
    expect(finalInfo.kernelExcess, s3.kernelExcess);
    expect(finalInfo.fee, fee);

    final bobBalance = await balanceOf(w.bob);
    expect(bobBalance.spendable, amount);
    expect(bobBalance.total, amount);
    // Alice mined 7 blocks; the fee came back to her in block 6.
    final aliceBalance = await balanceOf(w.alice);
    expect(aliceBalance.total, reward * BigInt.from(7) - amount);
    expect(aliceBalance.amountLocked, BigInt.zero);

    final aliceTxs = await w.alice.getTransactions();
    expect(aliceTxs.refreshedFromNode, isTrue);
    final a = aliceTxs.bySlateId(slateId)!;
    expect(a.type, GrinTxType.txSent);
    expect(a.confirmed, isTrue);
    expect(a.slateState, GrinSlateState.s3);
    expect(a.kernelExcess, s3.kernelExcess);
    expect(a.fee, fee);
    expect(a.hasStoredTx, isTrue);
    expect(a.counterpartyAddress, w.bobAddress);
    expect(a.armoredSlatepack, s3.armoredSlatepack);
    expect(a.paymentProof?.receiverSignaturePresent, isTrue);
    expect(a.paymentProof?.senderSignaturePresent, isTrue);
    expect(a.creationTime.isUtc, isTrue);
    expect(a.confirmationTime, isNotNull);
    expect(a.ttlCutoffHeight, isNull);
    expect(a.revertedAfterSecs, isNull);
    expect(
      aliceTxs.transactions
          .where((e) => e.type == GrinTxType.confirmedCoinbase)
          .length,
      greaterThanOrEqualTo(5),
    );

    final b = await entryFor(w.bob, slateId, refresh: true);
    expect(b.type, GrinTxType.txReceived);
    expect(b.confirmed, isTrue);
    expect(b.slateState, GrinSlateState.s2);
    expect(b.amountCredited, amount);
    expect(b.kernelExcess, s3.kernelExcess);
    expect(b.paymentProof, isNull);
    expect(b.counterpartyAddress, w.aliceAddress);
    expect(b.armoredSlatepack, s2.armoredSlatepack);
  });

  test('I1 -> I2 -> I3 locks the payer inputs', () async {
    // Height 6: heights 1 to 3 are mature.
    final w = await setUpWallets(blocks: 6);
    final amount = BigInt.from(30) * grin;

    final i1 = await w.bob.issueInvoice(
      GrinInvoiceArgs(amount: amount, recipientAddress: w.aliceAddress),
    );
    expect(i1.state, GrinSlateState.i1);
    expect(i1.isEncrypted, isTrue);
    expect(i1.sender, w.bobAddress);
    expect(i1.recipients, [w.aliceAddress]);
    expect(i1.amount, amount);
    expect(i1.fee, BigInt.zero);
    final slateId = i1.slateId;

    final issued = await entryFor(w.bob, slateId);
    expect(issued.type, GrinTxType.txReceived);
    expect(issued.slateState, GrinSlateState.i1);
    expect(issued.counterpartyAddress, w.aliceAddress);

    final spendable = (await balanceOf(w.alice)).spendable;
    expect(spendable, reward * BigInt.from(3));

    // An invoice for another amount than the one confirmed is refused
    // before anything is recorded or locked.
    final txsBefore = (await w.alice.getTransactions(refreshFromNode: false))
        .transactions
        .length;
    await expectLater(
      w.alice.processInvoice(
        i1.armoredSlatepack,
        GrinProcessInvoiceArgs(
          minimumConfirmations: 1,
          selectionStrategyIsAll: true,
          expectedAmount: amount - BigInt.one,
        ),
      ),
      throwsA(
        isA<GrinTransactionException>()
            .having(
              (e) => e.details?['invoice_amount'],
              'invoice_amount',
              amount.toInt(),
            )
            .having(
              (e) => e.details?['expected_amount'],
              'expected_amount',
              (amount - BigInt.one).toInt(),
            ),
      ),
    );
    final untouched = await balanceOf(w.alice, refresh: false);
    expect(untouched.spendable, spendable);
    expect(untouched.amountLocked, BigInt.zero);
    final txsAfter = await w.alice.getTransactions(refreshFromNode: false);
    expect(txsAfter.transactions, hasLength(txsBefore));
    expect(txsAfter.bySlateId(slateId), isNull);

    final i2 = await w.alice.processInvoice(
      i1.armoredSlatepack,
      GrinProcessInvoiceArgs(
        minimumConfirmations: 1,
        selectionStrategyIsAll: true,
        expectedAmount: amount,
      ),
    );
    expect(i2.state, GrinSlateState.i2);
    expect(i2.slateId, slateId);
    expect(i2.isEncrypted, isTrue);
    expect(i2.recipients, [w.bobAddress]);
    expect(i2.amount, amount);
    final fee = i2.fee;
    expect(fee, greaterThan(BigInt.zero));

    // The inputs are locked already, so the rest of the balance cannot be
    // spent before the invoice is finalized.
    final remaining = spendable - amount - fee;
    await expectLater(
      w.alice.initSend(
        GrinSendArgs(amount: remaining, minimumConfirmations: 1),
      ),
      throwsA(isA<GrinInsufficientFundsException>()),
    );
    final locked = await balanceOf(w.alice, refresh: false);
    expect(locked.spendable, BigInt.zero);
    expect(locked.amountLocked, greaterThanOrEqualTo(amount + fee));
    final paying = await entryFor(w.alice, slateId);
    expect(paying.type, GrinTxType.txSent);
    expect(paying.slateState, GrinSlateState.i2);
    expect(paying.counterpartyAddress, w.bobAddress);

    final i3 = await w.bob.finalizeInvoice(i2.armoredSlatepack);
    expect(i3.state, GrinSlateState.i3);
    expect(i3.posted, isTrue);
    expect(i3.amount, amount);
    expect(i3.fee, fee);
    // The broadcast mined height 7 and paid its coinbase, plus the fee, to
    // Bob.
    expect(await GrinTestChain.mineBlocks(w.alice, 1), 8);

    final bob = await balanceOf(w.bob);
    expect(bob.spendable, amount);
    expect(bob.amountImmature, reward + fee);
    final alice = await balanceOf(w.alice);
    expect(alice.total, reward * BigInt.from(7) - amount - fee);
    expect(alice.amountLocked, BigInt.zero);

    final bobEntry = await entryFor(w.bob, slateId, refresh: true);
    expect(bobEntry.slateState, GrinSlateState.i3);
    expect(bobEntry.confirmed, isTrue);
    expect(bobEntry.armoredSlatepack, i3.armoredSlatepack);
    final aliceEntry = await entryFor(w.alice, slateId, refresh: true);
    expect(aliceEntry.confirmed, isTrue);
    expect(aliceEntry.kernelExcess, i3.kernelExcess);

    final info = await GrinWalletClient.decodeSlatepackWithoutWallet(
      i3.armoredSlatepack,
      GrinNetwork.automatedTesting,
    );
    expect(info.state, GrinSlateState.i3);
    expect(info.kernelExcess, i3.kernelExcess);
  });

  test('cancel by slate id and by transaction id', () async {
    final w = await setUpWallets();
    final before = (await balanceOf(w.alice)).spendable;

    // No recipient: the S1 is not encrypted and the sender travels in the
    // clear.
    final s1 = await w.alice.initSend(
      GrinSendArgs(amount: BigInt.from(10) * grin, minimumConfirmations: 1),
    );
    expect(s1.isEncrypted, isFalse);
    expect(s1.recipients, isEmpty);
    final plain = await GrinWalletClient.decodeSlatepackWithoutWallet(
      s1.armoredSlatepack,
      GrinNetwork.automatedTesting,
    );
    expect(plain.isEncrypted, isFalse);
    expect(plain.sender, w.aliceAddress);
    final locked = await balanceOf(w.alice, refresh: false);
    expect(locked.spendable, lessThan(before));
    expect(locked.amountLocked, greaterThan(BigInt.zero));

    await w.alice.cancelTransaction(slateId: s1.slateId);
    expect(
      (await entryFor(w.alice, s1.slateId)).type,
      GrinTxType.txSentCancelled,
    );
    final freed = await balanceOf(w.alice, refresh: false);
    expect(freed.spendable, before);
    expect(freed.amountLocked, BigInt.zero);
    // Already cancelled.
    await expectLater(
      w.alice.cancelTransaction(slateId: s1.slateId),
      throwsA(isA<GrinTransactionException>()),
    );

    final second = await w.alice.initSend(
      GrinSendArgs(amount: BigInt.from(15) * grin, minimumConfirmations: 1),
    );
    final id = (await entryFor(w.alice, second.slateId)).id;
    await w.alice.cancelTransaction(txId: id);
    final cancelled = await entryFor(w.alice, second.slateId);
    expect(cancelled.type, GrinTxType.txSentCancelled);
    expect(cancelled.type.isCancelled, isTrue);
    expect((await balanceOf(w.alice, refresh: false)).spendable, before);

    await expectLater(
      w.alice.cancelTransaction(
        slateId: '6f1c3e1a-0d4b-4c39-9b6e-6c1f6f0d2a11',
      ),
      throwsA(isA<GrinNotFoundException>()),
    );
  });

  test('repost a finalized transaction that was not broadcast', () async {
    final w = await setUpWallets();
    final amount = BigInt.from(20) * grin;

    final s1 = await w.alice.initSend(
      GrinSendArgs(
        amount: amount,
        minimumConfirmations: 1,
        recipientAddress: w.bobAddress,
      ),
    );
    // Nothing is stored to post before the send is finalized.
    await expectLater(
      w.alice.repost(slateId: s1.slateId),
      throwsA(isA<GrinNotFoundException>()),
    );
    final s2 = await w.bob.receiveSlatepack(s1.armoredSlatepack);
    final s3 = await w.alice.finalizeSlatepack(
      s2.armoredSlatepack,
      broadcast: false,
    );
    expect(s3.posted, isFalse);
    final stored = await entryFor(w.alice, s1.slateId);
    expect(stored.hasStoredTx, isTrue);
    expect(stored.confirmed, isFalse);

    await w.alice.repost(slateId: s1.slateId);
    expect(await GrinTestChain.mineBlocks(w.alice, 1), 7);
    final confirmed = await entryFor(w.alice, s1.slateId, refresh: true);
    expect(confirmed.confirmed, isTrue);
    expect(confirmed.kernelExcess, s3.kernelExcess);
    expect((await balanceOf(w.bob)).spendable, amount);

    // A coinbase entry has nothing stored to post.
    final txs = await w.alice.getTransactions(refreshFromNode: false);
    final coinbase = txs.transactions.firstWhere(
      (e) => e.type == GrinTxType.confirmedCoinbase,
    );
    expect(coinbase.slateId, isNull);
    await expectLater(
      w.alice.repost(txId: coinbase.id),
      throwsA(isA<GrinNotFoundException>()),
    );
  });

  test('payment proof: export, verify, tamper', () async {
    final w = await setUpWallets();
    final amount = BigInt.from(25) * grin;

    final s1 = await w.alice.initSend(
      GrinSendArgs(
        amount: amount,
        minimumConfirmations: 1,
        recipientAddress: w.bobAddress,
      ),
    );
    final s2 = await w.bob.receiveSlatepack(s1.armoredSlatepack);
    final s3 = await w.alice.finalizeSlatepack(s2.armoredSlatepack);
    await GrinTestChain.mineBlocks(w.alice, 1);

    final proof = await w.alice.exportPaymentProof(slateId: s1.slateId);
    expect(proof.recipientAddress, w.bobAddress);
    expect(proof.senderAddress, w.aliceAddress);
    expect(proof.excess, s3.kernelExcess);
    expect(proof.amount, amount);

    final id = (await entryFor(w.alice, s1.slateId, refresh: true)).id;
    expect(await w.alice.exportPaymentProof(txId: id), proof);

    final asSender = await w.alice.verifyPaymentProof(proof);
    expect(asSender.isSender, isTrue);
    expect(asSender.isRecipient, isFalse);

    // The text round-trips, so a stored proof verifies the same way.
    final restored = GrinPaymentProof.fromJsonString(proof.toJsonString());
    expect(restored.toJsonString(), proof.toJsonString());
    final asRecipient = await w.bob.verifyPaymentProof(restored);
    expect(asRecipient.isSender, isFalse);
    expect(asRecipient.isRecipient, isTrue);

    final tampered = GrinPaymentProof.fromJson({
      ...proof.toJson(),
      'amount': '20',
    });
    await expectLater(
      w.bob.verifyPaymentProof(tampered),
      throwsA(isA<GrinException>()),
    );

    // Bob's side of a send keeps no proof.
    await expectLater(
      w.bob.exportPaymentProof(slateId: s1.slateId),
      throwsA(isA<GrinNotFoundException>()),
    );
  });

  test('errors', () async {
    final w = await setUpWallets();
    final s1 = await w.alice.initSend(
      GrinSendArgs(
        amount: BigInt.from(10) * grin,
        minimumConfirmations: 1,
        recipientAddress: w.bobAddress,
      ),
    );

    // Bad armor.
    await expectLater(
      GrinWalletClient.decodeSlatepackWithoutWallet(
        'not a slatepack',
        GrinNetwork.automatedTesting,
      ),
      throwsA(isA<GrinSlateException>()),
    );
    await expectLater(
      w.alice.decodeSlatepack('BEGINSLATEPACK. nonsense. ENDSLATEPACK.'),
      throwsA(isA<GrinSlateException>()),
    );
    await expectLater(
      w.bob.receiveSlatepack('not a slatepack'),
      throwsA(isA<GrinSlateException>()),
    );

    // Wrong state: an S1 is not an S2, and an S1 is not an I1. Neither
    // changes anything.
    await expectLater(
      w.alice.finalizeSlatepack(s1.armoredSlatepack),
      throwsA(isA<GrinSlateException>()),
    );
    await expectLater(
      w.alice.finalizeInvoice(s1.armoredSlatepack),
      throwsA(isA<GrinSlateException>()),
    );
    await expectLater(
      w.bob.processInvoice(s1.armoredSlatepack, const GrinProcessInvoiceArgs()),
      throwsA(isA<GrinSlateException>()),
    );
    final s2 = await w.bob.receiveSlatepack(s1.armoredSlatepack);
    await expectLater(
      w.bob.receiveSlatepack(s2.armoredSlatepack),
      throwsA(isA<GrinSlateException>()),
    );

    // Identifiers.
    await expectLater(
      w.alice.repost(),
      throwsA(isA<GrinInvalidArgumentException>()),
    );
    await expectLater(
      w.alice.cancelTransaction(),
      throwsA(isA<GrinInvalidArgumentException>()),
    );
    await expectLater(
      w.alice.exportPaymentProof(),
      throwsA(isA<GrinInvalidArgumentException>()),
    );

    // Amounts.
    expect(
      () => w.alice.estimateFee(amount: BigInt.from(-1)),
      throwsArgumentError,
    );
    expect(
      () => w.alice.estimateFee(amount: BigInt.one << 63),
      throwsArgumentError,
    );
    expect(
      () => w.alice.initSend(GrinSendArgs(amount: BigInt.from(-5))),
      throwsArgumentError,
    );
    await expectLater(
      w.alice.estimateFee(amount: BigInt.zero),
      throwsA(isA<GrinInvalidArgumentException>()),
    );
    final tooMuch = (await balanceOf(w.alice)).total * BigInt.from(10);
    await expectLater(
      w.alice.estimateFee(amount: tooMuch, minimumConfirmations: 1),
      throwsA(isA<GrinInsufficientFundsException>()),
    );

    // A send to a wallet that is not there fails before anything is locked.
    final before = await balanceOf(w.alice, refresh: false);
    await expectLater(
      w.alice.sendHttp(
        GrinHttpSendArgs(
          amount: grin,
          minimumConfirmations: 1,
          recipientUrlOrAddress: 'http://127.0.0.1:1',
        ),
      ),
      throwsA(isA<GrinHttpException>()),
    );
    expect(
      (await balanceOf(w.alice, refresh: false)).amountLocked,
      before.amountLocked,
    );

    // Addresses.
    await expectLater(
      w.alice.initSend(
        GrinSendArgs(amount: grin, recipientAddress: 'not-an-address'),
      ),
      throwsA(isA<GrinInvalidAddressException>()),
    );
  });

  test('armored Slatepack lengths', () async {
    // One 60 grin coinbase input and one change output per send. The
    // numbers go to stdout for inspection; the bounds only catch a large
    // change.
    final w = await setUpWallets(blocks: 6);
    final amount = BigInt.from(10) * grin;
    final lengths = <String, int>{};

    final s1Plain = await w.alice.initSend(
      GrinSendArgs(amount: amount, minimumConfirmations: 1),
    );
    expect(s1Plain.isEncrypted, isFalse);
    lengths['S1 plain'] = s1Plain.armoredSlatepack.length;
    final s2FromPlain = await w.bob.receiveSlatepack(s1Plain.armoredSlatepack);
    lengths['S2 (reply to plain S1, encrypted to sender)'] =
        s2FromPlain.armoredSlatepack.length;
    final s3FromPlain = await w.alice.finalizeSlatepack(
      s2FromPlain.armoredSlatepack,
      broadcast: false,
    );
    lengths['S3 (from plain S1)'] = s3FromPlain.armoredSlatepack.length;
    await w.alice.cancelTransaction(slateId: s1Plain.slateId);
    await w.bob.cancelTransaction(slateId: s1Plain.slateId);

    final s1 = await w.alice.initSend(
      GrinSendArgs(
        amount: amount,
        minimumConfirmations: 1,
        recipientAddress: w.bobAddress,
      ),
    );
    expect(s1.isEncrypted, isTrue);
    lengths['S1 encrypted, payment proof'] = s1.armoredSlatepack.length;
    final s2 = await w.bob.receiveSlatepack(s1.armoredSlatepack);
    lengths['S2 encrypted, payment proof'] = s2.armoredSlatepack.length;
    final s3 = await w.alice.finalizeSlatepack(s2.armoredSlatepack);
    lengths['S3 (with payment proof)'] = s3.armoredSlatepack.length;
    await GrinTestChain.mineBlocks(w.alice, 1);

    final i1Plain = await w.bob.issueInvoice(GrinInvoiceArgs(amount: amount));
    expect(i1Plain.isEncrypted, isFalse);
    lengths['I1 plain'] = i1Plain.armoredSlatepack.length;
    await w.bob.cancelTransaction(slateId: i1Plain.slateId);
    final i1 = await w.bob.issueInvoice(
      GrinInvoiceArgs(amount: amount, recipientAddress: w.aliceAddress),
    );
    expect(i1.isEncrypted, isTrue);
    lengths['I1 encrypted'] = i1.armoredSlatepack.length;
    final i2 = await w.alice.processInvoice(
      i1.armoredSlatepack,
      GrinProcessInvoiceArgs(minimumConfirmations: 1, expectedAmount: amount),
    );
    lengths['I2 encrypted'] = i2.armoredSlatepack.length;
    final i3 = await w.bob.finalizeInvoice(i2.armoredSlatepack);
    lengths['I3'] = i3.armoredSlatepack.length;

    for (final entry in lengths.entries) {
      stdout.writeln('slatepack length: ${entry.key}: ${entry.value}');
    }
    for (final length in lengths.values) {
      expect(length, inInclusiveRange(200, 6000));
    }
  });
}
