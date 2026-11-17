// Runs the repository's format, analysis, test, and build gates.
//
//   dart run tool/ci.dart                 # everything that runs on this host
//   dart run tool/ci.dart --list          # print the stages
//   dart run tool/ci.dart --only rust-test,dart-test
//   dart run tool/ci.dart --skip android,flutter-build
//
// Stages, in order:
//   rust-dups        cargo tree -d shows no duplicated grin or secp crates
//   rust-fmt         cargo fmt --check
//   rust-clippy      clippy with and without test-utils, -D warnings
//   rust-test        cargo test --features test-utils (includes the C11/C++11
//                    header test and the end-to-end chain tests)
//   rust-release     host release build; nm: 36 grin_ symbols, 0 grin_test_
//   android          release builds for aarch64, armv7 and x86_64 Android with
//                    NDK 28.2 through cargo-ndk; nm on each
//   bindings         tool/regen_bindings.dart --check (header and ffigen output
//                    are up to date)
//   dart-analyze     dart analyze --fatal-infos in packages/grin and in
//                    lib, test and hook of packages/grin_native
//   dart-format      dart format --set-exit-if-changed on the Dart sources
//   dart-test        dart test in packages/grin (pure Dart) and
//                    packages/grin_native (test_utils on)
//   web-smoke        packages/grin/lib imports no dart:ffi, dart:io or
//                    dart:isolate and no package but grin; then dart compile
//                    js of packages/grin/tool/web_smoke.dart (which fails on
//                    dart:ffi), run with node when it is installed
//   consumer         analyze and test packages/grin_native/test_consumer,
//                    which depends on grin_native alone and sends and
//                    receives on the test chain through GrinWalletApi
//   flutter-analyze  flutter analyze in packages/grin_native/example
//   flutter-test     flutter test in packages/grin_native/example
//   flutter-build    flutter build linux and apk (arm64) of the example
//
// The nm gate reads the dynamic symbol table (llvm-nm -D) for ELF files,
// so a stripped library is checked the same way as an unstripped one, and
// the COFF export table (llvm-readobj --coff-exports) for a DLL.
import 'dart:io';

const _ndkVersion = '28.2.13676358';
const _ndkHome = '/home/user/Android/Sdk/ndk/$_ndkVersion';
const _standardSymbolCount = 36;

const _androidTargets = {
  'aarch64-linux-android': 'arm64-v8a',
  'armv7-linux-androideabi': 'armeabi-v7a',
  'x86_64-linux-android': 'x86_64',
};

late final String root;
String get rust => '$root/packages/grin_native/rust';
String get grin => '$root/packages/grin';
String get grinNative => '$root/packages/grin_native';
String get example => '$root/packages/grin_native/example';
String get consumerPackage => '$root/packages/grin_native/test_consumer';

final List<String> _failures = [];
final List<String> _passed = [];

Future<void> main(List<String> args) async {
  root = _repoRoot();
  final only = _listArg(args, '--only');
  final skip = _listArg(args, '--skip');

  final stages = <String, Future<void> Function()>{
    'rust-dups': rustDups,
    'rust-fmt': rustFmt,
    'rust-clippy': rustClippy,
    'rust-test': rustTest,
    'rust-release': rustRelease,
    'android': android,
    'bindings': bindings,
    'dart-analyze': dartAnalyze,
    'dart-format': dartFormat,
    'dart-test': dartTest,
    'web-smoke': webSmoke,
    'consumer': consumer,
    'flutter-analyze': flutterAnalyze,
    'flutter-test': flutterTest,
    'flutter-build': flutterBuild,
  };
  if (args.contains('--list')) {
    stages.keys.forEach(stdout.writeln);
    return;
  }
  for (final name in [...only, ...skip]) {
    if (!stages.containsKey(name)) {
      stderr.writeln('unknown stage: $name');
      exit(2);
    }
  }
  for (final entry in stages.entries) {
    if (only.isNotEmpty && !only.contains(entry.key)) continue;
    if (skip.contains(entry.key)) continue;
    stdout.writeln('\n==> ${entry.key}');
    try {
      await entry.value();
      _passed.add(entry.key);
      stdout.writeln('==> ${entry.key}: ok');
    } on _GateFailure catch (e) {
      _failures.add('${entry.key}: ${e.message}');
      stdout.writeln('==> ${entry.key}: FAILED (${e.message})');
    }
  }
  stdout.writeln('\nSummary');
  for (final p in _passed) {
    stdout.writeln('  ok      $p');
  }
  for (final f in _failures) {
    stdout.writeln('  FAILED  $f');
  }
  exit(_failures.isEmpty ? 0 : 1);
}

// ---------------------------------------------------------------- stages

Future<void> rustDups() async {
  final out = await _capture('cargo', [
    'tree',
    '-d',
    '--edges',
    'normal',
  ], rust);
  final roots = out
      .split('\n')
      .where((l) => RegExp(r'^[A-Za-z0-9_-]+ v').hasMatch(l))
      .where((l) => RegExp('grin|secp', caseSensitive: false).hasMatch(l))
      .toList();
  if (roots.isNotEmpty) {
    throw _GateFailure('duplicated crates: ${roots.join(', ')}');
  }
  stdout.writeln('no duplicated grin or secp crates');
}

Future<void> rustFmt() =>
    _run('cargo', ['fmt', '-p', 'grin-ffi', '--', '--check'], rust);

Future<void> rustClippy() async {
  await _run('cargo', [
    'clippy',
    '-p',
    'grin-ffi',
    '--all-targets',
    '--features',
    'test-utils',
    '--',
    '-D',
    'warnings',
  ], rust);
  await _run('cargo', [
    'clippy',
    '-p',
    'grin-ffi',
    '--',
    '-D',
    'warnings',
  ], rust);
}

Future<void> rustTest() => _run('cargo', [
  'test',
  '-p',
  'grin-ffi',
  '--features',
  'test-utils',
  '--locked',
], rust);

Future<void> rustRelease() async {
  await _run('cargo', [
    'build',
    '-p',
    'grin-ffi',
    '--release',
    '--locked',
  ], rust);
  await _nmGate('$rust/target/release/libgrin_ffi.so');
}

Future<void> android() async {
  if (!Directory(_ndkHome).existsSync()) {
    throw _GateFailure('NDK $_ndkVersion not found at $_ndkHome');
  }
  for (final entry in _androidTargets.entries) {
    await _run(
      'cargo',
      [
        'ndk',
        '--target',
        entry.key,
        '--platform',
        '24',
        'build',
        '-p',
        'grin-ffi',
        '--release',
        '--locked',
      ],
      rust,
      environment: {'ANDROID_NDK_HOME': _ndkHome, 'ANDROID_NDK_ROOT': _ndkHome},
    );
    await _nmGate('$rust/target/${entry.key}/release/libgrin_ffi.so');
  }
}

Future<void> bindings() =>
    _run('dart', ['run', 'tool/regen_bindings.dart', '--check'], root);

Future<void> dartAnalyze() async {
  await _run('dart', ['analyze', '--fatal-infos'], grin);
  // Only grin_native's own sources: example/ and test_consumer/ are
  // packages of their own with their own stages.
  await _run('dart', [
    'analyze',
    '--fatal-infos',
    'lib',
    'test',
    'hook',
  ], grinNative);
}

Future<void> dartFormat() => _run('dart', [
  'format',
  '--set-exit-if-changed',
  'packages/grin',
  'packages/grin_native/hook',
  'packages/grin_native/lib',
  'packages/grin_native/test',
  'packages/grin_native/example/lib',
  'packages/grin_native/example/test',
  'packages/grin_native/example/integration_test',
  'packages/grin_native/test_consumer',
  'tool',
], root);

Future<void> dartTest() async {
  await _run('dart', ['test'], grin);
  await _run('dart', ['test'], grinNative);
}

// The URIs in [source]'s import and export directives that grin may not
// use: dart:ffi, dart:io, dart:isolate, and any package but grin. Every
// quoted URI of a directive is checked, in either quote style, so the
// conditional URIs after `if (...)` are covered as well.
List<String> _forbiddenUris(String source) {
  final directive = RegExp(r'^\s*(?:import|export)\b([^;]*);', multiLine: true);
  final quoted = RegExp(r"""(['"])(.*?)\1""");
  final forbidden = RegExp(r'^(?:dart:(?:ffi|io|isolate)|package:(?!grin/))');
  return [
    for (final d in directive.allMatches(source))
      for (final q in quoted.allMatches(d[1]!))
        if (forbidden.hasMatch(q[2]!)) q[2]!,
  ];
}

// Directives the check must catch and must let through, so a regression in
// _forbiddenUris fails the stage instead of passing everything.
const _purityCases = {
  "import 'dart:io';": ['dart:io'],
  'import "dart:ffi";': ['dart:ffi'],
  "import 'stub.dart' if (dart.library.io) 'dart:io';": ['dart:io'],
  "import 'stub.dart'\n    if (dart.library.isolate) \"dart:isolate\";": [
    'dart:isolate',
  ],
  "export 'package:other/other.dart';": ['package:other/other.dart'],
  "import 'package:grin/codec.dart';": <String>[],
  "import 'dart:convert' show jsonDecode;": <String>[],
  "// import 'dart:io';": <String>[],
};

Future<void> webSmoke() async {
  // dart compile js rejects dart:ffi but accepts dart:io and dart:isolate,
  // which only fail at run time, so those are checked here.
  for (final MapEntry(key: source, value: expected) in _purityCases.entries) {
    final found = _forbiddenUris(source);
    if (found.join(',') != expected.join(',')) {
      throw _GateFailure('purity check self-test: $source gave $found');
    }
  }
  final offenders = <String>[];
  for (final entity in Directory('$grin/lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final uri in _forbiddenUris(entity.readAsStringSync())) {
      offenders.add('${entity.path.substring(root.length + 1)}: $uri');
    }
  }
  if (offenders.isNotEmpty) {
    throw _GateFailure('native or foreign imports in grin: $offenders');
  }
  stdout.writeln('packages/grin/lib: no dart:ffi, dart:io, dart:isolate');
  final out = await Directory.systemTemp.createTemp('grin_web_smoke_');
  try {
    final js = '${out.path}/web_smoke.js';
    await _run('dart', [
      'compile',
      'js',
      '-o',
      js,
      'tool/web_smoke.dart',
    ], grin);
    final node = await Process.run('which', ['node']);
    if (node.exitCode != 0) {
      stdout.writeln('node not found; compiled only');
      return;
    }
    final result = await _capture('node', [js], root);
    stdout.write(result);
    if (!result.contains('web_smoke ok')) {
      throw _GateFailure('web_smoke.js did not print "web_smoke ok"');
    }
  } finally {
    await out.delete(recursive: true);
  }
}

Future<void> consumer() async {
  await _run('dart', ['analyze', '--fatal-infos'], consumerPackage);
  await _run('dart', ['test'], consumerPackage);
}

Future<void> flutterAnalyze() => _run('flutter', ['analyze'], example);

Future<void> flutterTest() => _run('flutter', ['test'], example);

Future<void> flutterBuild() async {
  await _run('flutter', ['build', 'linux'], example);
  await _run('flutter', [
    'build',
    'apk',
    '--target-platform',
    'android-arm64',
  ], example);
}

// ---------------------------------------------------------------- helpers

Future<void> _nmGate(String path) async {
  final file = File(path);
  if (!file.existsSync()) throw _GateFailure('missing $path');
  final List<String> symbols;
  if (path.endsWith('.dll')) {
    final out = await _capture('llvm-readobj', ['--coff-exports', path], root);
    symbols = RegExp(r'Name: (grin_\w+)')
        .allMatches(out)
        .map((m) => m.group(1)!)
        .toList();
  } else {
    final out = await _capture('llvm-nm', ['-D', '--defined-only', path], root);
    symbols = out
        .split('\n')
        .map((l) => l.trim().split(RegExp(r'\s+')))
        .where((p) => p.length >= 3 && p.last.startsWith('grin_'))
        .map((p) => p.last)
        .toList();
  }
  final test = symbols.where((s) => s.startsWith('grin_test_')).toList();
  final standard = symbols.where((s) => !s.startsWith('grin_test_')).toSet();
  stdout.writeln(
    'nm ${file.uri.pathSegments.last}: ${standard.length} standard, '
    '${test.length} test symbols',
  );
  if (test.isNotEmpty) {
    throw _GateFailure('$path exports test symbols: ${test.join(', ')}');
  }
  if (standard.length != _standardSymbolCount) {
    throw _GateFailure(
      '$path exports ${standard.length} grin_ symbols, expected '
      '$_standardSymbolCount',
    );
  }
}

Future<void> _run(
  String exe,
  List<String> args,
  String cwd, {
  Map<String, String> environment = const {},
}) async {
  stdout.writeln('\$ (cd $cwd && $exe ${args.join(' ')})');
  final process = await Process.start(
    exe,
    args,
    workingDirectory: cwd,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) throw _GateFailure('$exe exited with $code');
}

Future<String> _capture(
  String exe,
  List<String> args,
  String cwd, {
  Map<String, String> environment = const {},
}) async {
  stdout.writeln('\$ (cd $cwd && $exe ${args.join(' ')})');
  final result = await Process.run(
    exe,
    args,
    workingDirectory: cwd,
    environment: environment,
  );
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw _GateFailure('$exe exited with ${result.exitCode}');
  }
  return result.stdout as String;
}

List<String> _listArg(List<String> args, String name) {
  final values = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == name && i + 1 < args.length) {
      values.addAll(args[i + 1].split(','));
    } else if (args[i].startsWith('$name=')) {
      values.addAll(args[i].substring(name.length + 1).split(','));
    }
  }
  return values.where((v) => v.isNotEmpty).toList();
}

String _repoRoot() {
  var dir = Directory.current;
  while (!Directory('${dir.path}/packages/grin').existsSync() ||
      !File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      stderr.writeln('run from inside the grin repository');
      exit(2);
    }
    dir = parent;
  }
  return dir.path;
}

class _GateFailure implements Exception {
  _GateFailure(this.message);
  final String message;
}
