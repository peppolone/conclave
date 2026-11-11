# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First public release.

### Added

- Debates in rounds between up to 10 models: independent answers, anonymous cross-critique with a
  randomly chosen devil's advocate, revision, final position (0–3 rounds), then a verdict by a
  judge of your choice. Round 3 is skipped when nobody changes position.
- Judge fallback: if the chosen judge fails, Claude and then the other participants are tried.
- Short debate titles written by the judge; follow-up questions on a finished debate.
- One voice per model family with an automatic fallback chain: slow, rate-limited or retired
  variants are replaced by the next one, and the variant that answers is preferred afterwards.
- Startup health check that replaces models retired by the provider with the best catalog match
  and saves the choice; results cached for 12 hours.
- Providers: Claude through the official Claude Code CLI (existing subscription) and any
  OpenAI-compatible API (Gemini, Groq, OpenRouter, Mistral, Cerebras, OpenAI).
- Native macOS interface (AppKit + SwiftUI): sidebar history with search (case- and
  accent-insensitive), live debate view that follows the rounds, Markdown renderer with tables,
  Markdown export, text zoom, light/dark/system theme, Italian and English localization, open at
  login and menu bar extra.
- Debates left running in the background keep being tracked, with notification and Dock badge.
- Weekly update check against GitHub Releases (opt-out, never installs anything).
- macOS 26 app icon built with Icon Composer.
- Universal app (Apple Silicon + Intel) with Node 24 bundled, distributed as a DMG with SHA-256
  checksums.
- Engine stress suite (`npm run test:chaos`) with a mock provider: blocked, slow, rate-limited,
  failing, empty, oversized and retired models, cancellation and hostile input.

### Security

- API keys stored in the macOS Keychain and passed to the engine on standard input.
- Local engine bound to `127.0.0.1`, `Host` header check, per-session bearer token.
- Secrets masked in provider errors and in `server.log`.
- Data folder `0700`, files `0600`; atomic writes for settings and health cache.
- Claude CLI run without tools, MCP servers or user settings, and stopped on shutdown.

[0.1.0]: https://github.com/peppolone/conclave/releases/tag/v0.1.0
