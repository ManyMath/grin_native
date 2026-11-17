import '../internal/json_helpers.dart';

/// The result of checking a mnemonic phrase.
final class GrinMnemonicValidation {
  /// Creates a validation result.
  const GrinMnemonicValidation({required this.valid, required this.wordCount});

  /// Reads the native `grin_mnemonic_validate` document.
  factory GrinMnemonicValidation.fromJson(Map<String, Object?> json) {
    return GrinMnemonicValidation(
      valid: readBool(json['valid'], 'valid'),
      wordCount: readInt(json['word_count'], 'word_count'),
    );
  }

  /// Whether every word is on the BIP39 English list, the checksum matches
  /// and the length is allowed. A bad phrase is a result, not an error.
  final bool valid;

  /// The number of whitespace-separated words, valid or not.
  final int wordCount;

  @override
  bool operator ==(Object other) =>
      other is GrinMnemonicValidation &&
      other.valid == valid &&
      other.wordCount == wordCount;

  @override
  int get hashCode => Object.hash(valid, wordCount);

  @override
  String toString() =>
      'GrinMnemonicValidation(valid: $valid, wordCount: $wordCount)';
}
