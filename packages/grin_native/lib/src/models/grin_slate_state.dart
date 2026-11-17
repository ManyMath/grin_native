/// The state of a slate in the Slatepack protocol.
///
/// The names are the strings of the native library (`S1`, `S2`, `S3`, `I1`,
/// `I2`, `I3`, `Unknown`). A send runs S1, S2, S3 and an invoice I1, I2, I3.
enum GrinSlateState {
  /// A send, started by the sender.
  s1('S1'),

  /// A send, answered by the recipient.
  s2('S2'),

  /// A send, finalized by the sender.
  s3('S3'),

  /// An invoice, issued by the payee.
  i1('I1'),

  /// An invoice, paid by the payer.
  i2('I2'),

  /// An invoice, finalized by the payee.
  i3('I3'),

  /// A slate of a version before V4, or a state this package does not know.
  unknown('Unknown');

  const GrinSlateState(this.wireName);

  /// The string used by the native library.
  final String wireName;

  /// The state named by [value]. Anything unrecognized is [unknown].
  static GrinSlateState parse(String value) {
    for (final state in values) {
      if (state.wireName == value) return state;
    }
    return unknown;
  }
}
