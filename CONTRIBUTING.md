# Contributing to Conclave

Thanks for your interest. Bug reports, fixes and focused improvements are welcome. For larger
changes, please open an issue first so we can agree on the approach.

## Setup

Requirements: macOS 26, Xcode (for `swiftc` and `actool`), Node.js 24.

```bash
git clone https://github.com/peppolone/conclave.git
cd conclave
npm ci
```

- `npm start` — runs the engine alone on `http://localhost:4848`, data in the project folder,
  keys from `.env` (copy `.env.example`). Development only: no token is required in this mode.
- `npm run app` — builds `dist/Conclave.app`; `npm run app:install` also copies it to
  `/Applications`.

macOS asks again for Keychain access after each rebuild (there is no Apple Developer Team ID).
This is expected.

## Checks before a pull request

```bash
npm run typecheck    # must report 0 errors
npm run test:chaos   # required if you touched src/ (takes about 2 minutes, all scenarios must pass)
npm run app          # required if you touched macos/; no new compiler warnings
```

CI runs the same checks on every pull request, plus a secret scan.

For interface changes, include before/after screenshots in light and dark mode.

## Testing without real keys

- **Never use real API keys or your Claude subscription in tests**, and never commit them.
  `.env`, `selection.json`, `health.json`, databases and logs are ignored by git.
- The chaos suite (`tests/chaos/`) runs against a mock OpenAI-compatible provider
  (`tests/chaos/mock-provider.mjs`). Point the app or the engine at it with `COUNCIL_MODELS=<config>`
  and use a temporary `COUNCIL_DATA` folder so your own data is never touched.
- Every engine fix or feature should come with a chaos scenario that would have caught the problem.
  Try actively to break what you changed: slow, failing, empty or malformed provider responses,
  cancellation, hostile input.

## Conventions

- **Commits**: small, one topic each, [Conventional Commits](https://www.conventionalcommits.org/)
  in English (`feat(app): …`, `fix(engine): …`, `ci: …`).
- **Interface text** is written in Italian in the code and translated in
  `macos/l10n/<lang>.lproj/Localizable.strings` (the key is the Italian text). Every new
  user-facing string needs its English translation in `macos/l10n/en.lproj`.
- **Swift UI** stays fully native (AppKit/SwiftUI, no web views). Use the color tokens in
  `Brand.swift`, never hard-coded colors.
- **Engine** (`src/`): TypeScript run directly by Node 24, no runtime npm dependencies. Keep the
  HTTP/SSE fields used by the app stable (`CouncilStore.swift` depends on them).
- Do not log or display secrets; route new error messages through the existing redaction.

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please do not open public issues for vulnerabilities.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
