/// The native Grin wallet backend, over the grin-ffi Rust library.
///
/// The library is built by this package's build hook. It includes the shared
/// wallet API, models and exceptions, so an app depends on and imports
/// grin_native alone. Start with [GrinWalletClient], or with
/// [GrinNativeBackend] where code takes a [GrinWalletBackend].
library;

export 'grin.dart';

export 'src/wallet/grin_native_backend.dart';
export 'src/wallet/grin_wallet_client.dart';
