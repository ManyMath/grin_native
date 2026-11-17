# grin

`grin` provides the backend-neutral Dart API for a Grin wallet.

It includes:

- `GrinWalletBackend` for creating, opening, deleting, and validating wallets
- `GrinWalletApi` for balances, scans, transactions, Slatepack exchanges,
  invoices, cancellation, reposting, and payment proofs
- typed models, wallet events, and a sealed `GrinException` hierarchy
- `parseGrin` and `formatGrin` for exact `BigInt` nanogrin amounts

The package has no native code or runtime dependencies, so application code
can use the same interfaces with a native backend or a test fake.

```dart
import 'package:grin/grin.dart';

Future<String> addressFor(
  GrinWalletBackend backend,
  GrinWalletConfig config,
) async {
  final wallet = await backend.open(config: config, password: 'password');
  try {
    return (await wallet.getAddress()).slatepackAddress;
  } finally {
    await wallet.close();
  }
}
```
