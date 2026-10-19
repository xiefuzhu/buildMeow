# Repository Guidelines

## Project Structure & Module Organization

- `app/lib/main.dart` starts Flutter; `app/lib/src/` groups pages, widgets, Riverpod state, data processing, and window controls. Tests live in `app/test/`, fonts in `app/assets/fonts/`, and native targets in `app/android/` and `app/windows/`.
- `app/installer/` defines the Windows beta installer; `app/tool/build_installer.ps1` packages a complete release with its icon and runtime DLLs. `app/tool/verify_installer.ps1` checks installation in an isolated directory and refuses to replace an existing beta installation.
- `packages/mapart_core/` is Flutter-independent Dart code: public API in `lib/mapart_core.dart`, implementations in `lib/src/`, tests in `test/`, and color tables, textures, and block names in `assets/`.
- `packages/mapart_core/tool/` contains generators and diagnostic scripts; `doc/` records algorithm findings. `方块贴图/` holds source block textures.

## Build, Test, and Development Commands

The app requires Dart `>=3.13.0 <4.0.0`; Windows builds require Visual Studio's C++ desktop workload. Run commands from the indicated directory:

| Directory | Command | Purpose |
| --- | --- | --- |
| `packages/mapart_core/` | `dart pub get` | Resolve core dependencies. |
| `packages/mapart_core/` | `dart analyze` | Check core types and lints. |
| `packages/mapart_core/` | `dart test` | Run core tests with package-relative assets. |
| `app/` | `flutter pub get` | Resolve app dependencies. |
| `app/` | `flutter analyze` | Lint Flutter code. |
| `app/` | `powershell -File tool/run_tests.ps1` | Run app tests separately, retrying failures. |
| `app/` | `flutter run -d windows` | Launch locally. |
| `app/` | `flutter build windows --release` | Build Windows release. |

## Coding Style & Naming Conventions

Use two-space indentation, `snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members. Run `dart format lib test tool` within each package. Follow `flutter_lints` in the app and recommended Dart lints with strict typing in the core; prefer final locals and explicit types where inference is unclear.

## Testing Guidelines

Use `package:test` for core tests and `flutter_test` for app tests; name files `*_test.dart`. Cover changed algorithms, export round trips, and widget interactions. No numeric coverage threshold is configured. From `app/`, run individual tests with `flutter test test/title_bar_test.dart`. Use the full-suite script for the Windows test-process crashes documented in `README.md`.

## Commit & Pull Request Guidelines

The repository has no commits yet. Use concise, imperative, scoped messages, such as `fix(core): preserve export block states`. Keep changes focused. PRs should describe behavior changes, reference related issues when applicable, list validation results and tested platforms, and include screenshots for UI changes.

## Assets & Attribution

Regenerate derived data with the relevant `tool/` scripts. Preserve vendored data provenance and update asset notices and `THIRD_PARTY_NOTICES.md` when sources change. Keep build output and `.dart_tool/` out of commits.
