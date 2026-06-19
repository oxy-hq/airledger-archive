/// Singleton + feature-flag hub for the airledger-engine Rust binding.
///
/// The engine is loaded lazily on first use — `AirledgerEngine.load()`
/// opens `libairledger_engine.so` from the app's nativeLibraryDir
/// (the .so files come from `~/repos/airledger/sdk-dart/build/jniLibs/`
/// via the gradle `sourceSets.jniLibs.srcDirs` wiring).
///
/// Flip [`useEngine`] off if a regression slips in and you need to
/// fall back to the pure-Dart parsers/repositories while you debug.
library;

import 'package:airledger_engine/airledger_engine.dart';

/// When true, schema parsing (and eventually sheets ingest) route
/// through the Rust engine instead of the pure-Dart code in
/// `services/schema_parser.dart`, `services/input_parser.dart`, and
/// `services/sheets_repository.dart`.
///
/// Reverting to false should require no other changes — both paths
/// stay compiled in.
const useEngine = true;

AirledgerEngine? _engine;

/// Lazily load and cache the engine. Subsequent calls return the
/// same instance (the underlying [`DynamicLibrary.open`] is also
/// process-cached but we keep the wrapper around for the bindings).
AirledgerEngine getEngine() => _engine ??= AirledgerEngine.load();
