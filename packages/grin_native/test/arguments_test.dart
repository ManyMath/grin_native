import 'package:grin_native/codec.dart';
import 'package:grin_native/grin_native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('integer argument checks', () {
    test('requireU32 accepts 0 and 2^32 - 1 only', () {
      expect(requireU32(0, 'x'), 0);
      expect(requireU32(0xFFFFFFFF, 'x'), 0xFFFFFFFF);
      expect(() => requireU32(-1, 'x'), throwsArgumentError);
      expect(() => requireU32(0x100000000, 'x'), throwsArgumentError);
      expect(() => requireU32(0x100000005, 'x'), throwsArgumentError);
    });

    test('requireU64 refuses a negative number', () {
      expect(requireU64(0, 'x'), 0);
      expect(requireU64(0x7FFFFFFFFFFFFFFF, 'x'), 0x7FFFFFFFFFFFFFFF);
      expect(() => requireU64(-1, 'x'), throwsArgumentError);
    });

    test('txIdToNative maps null to -1 and refuses a negative id', () {
      expect(txIdToNative(null), -1);
      expect(txIdToNative(0), 0);
      expect(txIdToNative(42), 42);
      expect(() => txIdToNative(-1), throwsArgumentError);
      expect(() => txIdToNative(-5), throwsArgumentError);
    });

    test('generateMnemonic refuses a word count that would be truncated', () {
      // 2^32 + 12 would reach the native side as 12.
      expect(
        () => GrinWalletClient.generateMnemonic(wordCount: 0x10000000C),
        throwsArgumentError,
      );
      expect(
        () => GrinWalletClient.generateMnemonic(wordCount: -1),
        throwsArgumentError,
      );
    });

    test('the client refuses out of range arguments before any call', () async {
      final dir = await makeTempDir();
      final wallet = await createTestWallet(dir);
      // u32 parameter.
      expect(() => wallet.getAddress(index: 1 << 32), throwsArgumentError);
      expect(() => wallet.getAddress(index: -1), throwsArgumentError);
      expect(
        () => wallet.decodeSlatepack('x', secretIndex: 1 << 32),
        throwsArgumentError,
      );
      // u64 parameters.
      expect(
        () => wallet.getBalance(minimumConfirmations: -1),
        throwsArgumentError,
      );
      expect(
        () => wallet.estimateFee(amount: BigInt.one, minimumConfirmations: -1),
        throwsArgumentError,
      );
      expect(() => wallet.scan(startHeight: -1), throwsArgumentError);
      // An explicit negative transaction id.
      expect(() => wallet.repost(txId: -1), throwsArgumentError);
      expect(() => wallet.cancelTransaction(txId: -1), throwsArgumentError);
      expect(() => wallet.exportPaymentProof(txId: -1), throwsArgumentError);
      // The largest u32 index still works.
      expect((await wallet.getAddress(index: 0xFFFFFFFF)).index, 0xFFFFFFFF);
    });
  });

  group('GrinException.slateId', () {
    test('reads details.slate_id', () {
      final error = GrinException.fromJson(
        9,
        '{"code":9,"message":"node refused","details":{"slate_id":"abc-123"}}',
      );
      expect(error, isA<GrinNodeException>());
      expect(error.slateId, 'abc-123');
    });

    test('is null when it is missing or not a string', () {
      expect(GrinException.fromJson(9, '{"message":"m"}').slateId, isNull);
      expect(
        GrinException.fromJson(9, '{"message":"m","details":{}}').slateId,
        isNull,
      );
      expect(
        GrinException.fromJson(
          9,
          '{"message":"m","details":{"slate_id":5}}',
        ).slateId,
        isNull,
      );
      expect(GrinException.fromJson(9, 'not json').slateId, isNull);
    });
  });

  group('lenient parsing', () {
    test('an unknown address kind becomes GrinAddressKind.unknown', () {
      final validation = GrinAddressValidation.fromJson({
        'kind': 'carrier_pigeon',
        'url': 'http://example.invalid',
      });
      expect(validation.kind, GrinAddressKind.unknown);
      expect(validation.url, 'http://example.invalid');
      expect(
        GrinAddressValidation.fromJson({'kind': 'onion', 'url': 'u'}).kind,
        GrinAddressKind.onion,
      );
    });

    test('readBigInt refuses negative amounts', () {
      expect(readBigInt(5, 'a'), BigInt.from(5));
      expect(
        readBigInt('18446744073709551615', 'a'),
        BigInt.parse('18446744073709551615'),
      );
      expect(() => readBigInt(-1, 'a'), throwsFormatException);
      expect(() => readBigInt('-5', 'a'), throwsFormatException);
      expect(() => readBigInt('x', 'a'), throwsFormatException);
      expect(() => readBigInt(1.5, 'a'), throwsFormatException);
    });
  });
}
