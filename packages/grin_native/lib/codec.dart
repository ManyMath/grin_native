/// JSON decoding and native argument checks for wallet backends.
///
/// `package:grin_native/grin_native.dart` does not export this library. It is
/// used by the native backend to read grin-ffi output with the same rules as
/// the models. Apps do not need it.
library;

export 'src/internal/json_helpers.dart';
