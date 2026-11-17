# grin_native

`grin_native` provides a Grin wallet API and implements it with a Rust library
built from the Grin wallet crates. Its Dart build hook compiles and bundles
the native library as a code asset for Dart and Flutter applications.

`GrinWalletClient` implements `GrinWalletApi`, while `GrinNativeBackend`
implements `GrinWalletBackend`. The shared interfaces, models and exceptions
are included in the same package.

Wallet calls are serialized per wallet and run outside the main isolate.
Native handles are closed deterministically, with a finalizer as a fallback.
The backend supports scanning, Slatepack sends and invoices, HTTP transport,
transaction cancellation and reposting, and payment proofs.

```dart
import 'package:grin_native/grin_native.dart';

final wallet = await GrinWalletClient.open(
  config: const GrinWalletConfig(
    walletDir: '/data/grin/main',
    network: GrinNetwork.mainnet,
    nodeUrl: 'https://grinnode.example.com:3413',
  ),
  password: 'password',
);

final balance = await wallet.getBalance();
await wallet.close();
```
