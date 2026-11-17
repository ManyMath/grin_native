import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// Builds libgrin_ffi from `rust/` with the host Rust toolchain (rustup and
/// cargo, at the version pinned by `rust/rust-toolchain.toml`) and bundles it
/// as the code asset that `lib/src/ffi/bindings.g.dart` binds to.
///
/// One user-define, `test_utils` (bool, default false, under
/// `hooks.user_defines.grin_native`), adds `--features test-utils`, which exports
/// the grin_test_* functions the Dart tests drive an in-process chain with.
/// Never set it in an app.
///
/// The library is built from source for the requested target.
Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;

  final config = input.config.code;
  final target = _rustTarget(config);
  final variable = target.replaceAll('-', '_');
  final linker = 'CARGO_TARGET_${variable.toUpperCase()}_LINKER';
  final testUtils = _boolUserDefine(
    'test_utils',
    input.userDefines['test_utils'],
  );
  final environment = <String, String>{
    // Cargo reads this variable for git dependencies. rust/.cargo/config.toml
    // sets the same thing, but cargo looks for config files from its working
    // directory and the hook runs from elsewhere, so it is not seen. The
    // hooks runner filters the environment, so no ssh agent (SSH_AUTH_SOCK)
    // is reachable from here: the git database must already hold the fork's
    // rev, or the fork must be fetchable with a default ssh key.
    'CARGO_NET_GIT_FETCH_WITH_CLI': 'true',
    // A build has nobody to answer a prompt, and the hook's output is
    // captured, so a question from git or ssh (a username, a key
    // passphrase, an unknown host key) would look like a build that hangs.
    // Make both fail instead. ssh asks through an askpass program when it
    // is forced to, and this one answers nothing; ssh older than 8.4
    // ignores the variable and behaves as before. The user's own ssh
    // command and configuration are left alone.
    'GIT_TERMINAL_PROMPT': '0',
    'SSH_ASKPASS_REQUIRE': 'force',
    'SSH_ASKPASS': 'false',
    // Inside an Xcode build, PATH starts with Xcode's SwiftBuild and Metal
    // toolchain directories. Under that PATH, with the crate's
    // `strip = "debuginfo"`, the host proc-macro dylibs rustc strips no
    // longer load (arc-swap fails with "can't find crate for rustversion";
    // reproduced on macOS 26 with Xcode 27 by setting that PATH alone, and
    // gone with strip = none). Xcode strips the final product itself, so
    // keep debuginfo on Apple.
    if (config.targetOS == OS.macOS || config.targetOS == OS.iOS)
      'CARGO_PROFILE_RELEASE_STRIP': 'none',
    // The deployment floors. Without them rustc links for iOS 10 while
    // Xcode's clang compiles the C code (secp256k1-zkp, lmdb) for the SDK's
    // own version, and the iOS 10 runtime lacks ___chkstk_darwin.
    if (config.targetOS == OS.macOS)
      'MACOSX_DEPLOYMENT_TARGET': '${config.macOS.targetVersion}.0',
    if (config.targetOS == OS.iOS)
      'IPHONEOS_DEPLOYMENT_TARGET': '${config.iOS.targetVersion}.0',
    // LMDB (built by the cc crate, which reads CFLAGS_<target>) uses SysV
    // semaphores on Apple targets by default, and the App Sandbox denies
    // them (EPERM from mdb_env_open). Keep the lock in lock.mdb with pthread
    // mutexes instead; Apple has no robust mutexes, so turn those off. The
    // flags match flutter_libmwc's hook.
    if (config.targetOS == OS.macOS || config.targetOS == OS.iOS)
      'CFLAGS_$variable': '-DMDB_USE_POSIX_MUTEX=1 -DMDB_USE_ROBUST=0',
  };
  final compiler = config.cCompiler;
  if (config.targetOS == OS.android && compiler != null) {
    // RustBuilder links with the NDK's newest API clang; link for the app's
    // minSdk instead, so no symbol newer than the floor is pulled in.
    final ndkTarget = target.replaceFirst('armv7-', 'armv7a-');
    final api = config.android.targetNdkApi;
    final suffix = Platform.isWindows ? '.cmd' : '';
    final cc = compiler.compiler
        .resolve('$ndkTarget$api-clang$suffix')
        .toFilePath();
    environment.addAll({
      'CC_$variable': cc,
      'CXX_$variable': compiler.compiler
          .resolve('$ndkTarget$api-clang++$suffix')
          .toFilePath(),
      linker: cc,
    });
  } else if (config.targetOS == OS.linux && compiler != null) {
    environment.addAll({
      'CC_$variable': compiler.compiler.toFilePath(),
      'AR_$variable': compiler.archiver.toFilePath(),
      linker: compiler.compiler.toFilePath(),
    });
  }

  await RustBuilder(
    assetName: 'src/ffi/bindings.g.dart',
    cratePath: 'rust',
    extraCargoBuildArgs: [
      '--locked',
      '--lib',
      if (testUtils) ...['--features', 'test-utils'],
    ],
    extraCargoEnvironmentVariables: environment,
  ).run(input: input, output: output);

  // Cargo's dep-info lists compiled sources only; also rerun when a
  // manifest, the lock file or a newly added file in the crate changes.
  output.dependencies.addAll(_sourceDependencies(input.packageRoot));
});

/// The cargo target triple for the asset being built.
String _rustTarget(CodeConfig config) =>
    switch ((config.targetOS, config.targetArchitecture)) {
      (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
      (OS.android, Architecture.arm64) => 'aarch64-linux-android',
      (OS.android, Architecture.x64) => 'x86_64-linux-android',
      (OS.iOS, Architecture.arm64)
          when config.iOS.targetSdk == IOSSdk.iPhoneSimulator =>
        'aarch64-apple-ios-sim',
      (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
      (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      _ => throw UnsupportedError(
        'grin_native: unsupported target '
        '${config.targetOS}/${config.targetArchitecture}',
      ),
    };

/// A boolean user-define: absent means false; YAML booleans and the strings
/// `true` and `false` are accepted.
bool _boolUserDefine(String key, Object? value) => switch (value) {
  null || false || 'false' => false,
  true || 'true' => true,
  _ => throw ArgumentError(
    'grin_native: user-define "$key" must be true or false, not "$value".',
  ),
};

/// Every file under `rust/` except cargo's `target/` output.
Iterable<Uri> _sourceDependencies(Uri packageRoot) sync* {
  final crate = Directory.fromUri(packageRoot.resolve('rust/'));
  if (!crate.existsSync()) return;
  final target = crate.uri.resolve('target/').toFilePath();
  for (final entity in crate.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (entity.path.startsWith(target)) continue;
    yield entity.uri;
  }
}
