# Repository Guidelines

## Project Structure & Module Organization
This is a HarmonyOS entry app with ArkTS UI and native C++ streaming logic.

- `app/src/main/ets/`: ArkTS source
- `app/src/main/ets/pages/`: UI pages (for example `Index.ets`, `ControlPage.ets`)
- `app/src/main/ets/client/`: stream/control client logic
- `app/src/main/ets/helper/`: shared helpers (logging, session, server args)
- `app/src/main/cpp/`: native NAPI bridge, ADB transport, decoders
- `app/src/main/resources/`: localized strings and assets (`base`, `en_US`, `zh_CN`)
- `app/src/test/`: local unit tests (`*.test.ets`)
- `app/src/ohosTest/`: device/ability tests
- `sample/`: external demos; do not treat as core app code

## Build, Test, and Development Commands
Use DevEco Studio terminal (or a shell with Hvigor available).

- `hvigor clean`: clean build outputs
- `hvigor assembleHap`: build debug HAP
- `hvigor --mode module -p module=app@default -p product=default assembleHap`: build module explicitly
- `hvigor --mode module -p module=app@ohosTest test`: run `ohosTest` suite

If a wrapper script exists in your environment, use `hvigorw.bat`/`hvigorw` instead of `hvigor`.

## Coding Style & Naming Conventions
- ArkTS: 2-space indentation, `camelCase` for variables/functions, `PascalCase` for classes/components/files.
- C++: follow existing style (4-space indentation, clear thread/lifecycle comments where needed).
- Prefer descriptive logger tags and structured messages (see `Logger*.ets` usage).
- Keep localization keys stable; add new text to `base`, `en_US`, and `zh_CN` together.
- Run lint/checks configured in `code-linter.json5`, `.clang-tidy`, and `.clangd`.

## Testing Guidelines
- Framework: `@ohos/hypium`.
- Place fast unit tests in `app/src/test/`; integration/ability scenarios in `app/src/ohosTest/`.
- Name tests with `*.test.ets`; keep suite names behavior-focused (for example `ClientSessionManagerTest`).
- Add tests for connection lifecycle changes (connect, disconnect, background/foreground, cleanup).

## Commit & Pull Request Guidelines
- Commit style in this repo is short and imperative (often Chinese), for example: `修复意外断开连接后卡死的问题`.
- Keep one logical change per commit; include resource updates with related code changes.
- PRs should include:
- What changed and why
- Affected modules/files
- Test evidence (manual steps or test command output)
- Screenshots/recordings for UI behavior changes

## Security & Configuration Tips
- Never commit real signing materials, private keys, or local certificate paths.
- Review `build-profile.json5` changes carefully; keep machine-specific credentials out of shared history.
