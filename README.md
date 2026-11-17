# grin_native

`grin_native` is a native Grin wallet backend for Dart and Flutter. It wraps
the Grin wallet Rust crates behind a C ABI and includes its Dart API, models,
exceptions and native implementation in one package.

The Dart build hook compiles and bundles the Rust library as a native code
asset. `GrinWalletClient` provides wallet operations, while
`GrinNativeBackend` lets applications depend on the shared
`GrinWalletBackend` interface.

Wallet calls are serialized per wallet and run outside the main isolate.
The backend supports scanning, balances and history, Slatepack sends and
invoices, HTTP transport, cancellation and reposting, and payment proofs.

The package source is in
[`packages/grin_native`](packages/grin_native).
