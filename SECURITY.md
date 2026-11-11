# Security Policy

## Supported versions

Conclave is a small project maintained in spare time. Only the **latest release** receives
security fixes; please update before reporting.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub:
[**Security ▸ Report a vulnerability**](https://github.com/peppolone/conclave/security/advisories/new)
(private vulnerability reporting). Include the Conclave version, macOS version, Mac model
(Apple Silicon or Intel), steps to reproduce and the impact you expect.

Never include real API keys, Claude credentials or private debate content in a report; redact
them or use dummy values.

You should get a first answer within a week. Once a fix is released, the advisory is published
with credit to the reporter unless you prefer otherwise.

## Threat model

Conclave is a local, single-user desktop app. What it protects, and what it does not:

**In scope**

- **API keys.** Stored in the macOS Keychain (service `io.github.peppolone.conclave`), passed to
  the local engine on its standard input, never written to disk or to environment variables, and
  masked in logs and in provider error messages shown in the app.
- **Local engine API.** Listens only on `127.0.0.1`, accepts only `localhost`/`127.0.0.1` as
  `Host` (against DNS rebinding), requires `Content-Type: application/json` on state-changing
  requests, and requires a random per-session bearer token that the app generates at launch and
  passes on standard input. Other local processes and web pages should not be able to read the
  history, start debates or spend your quotas.
- **Data at rest.** `~/Library/Application Support/Conclave/` is created with mode `0700` and its
  files `0600`.
- **Claude CLI.** Invoked with tools disabled, no MCP servers, no user settings, an empty working
  directory and without `ANTHROPIC_API_KEY`; it is stopped when the engine shuts down.
- **Model output.** Rendered as Markdown by a native renderer; HTML in model answers is never
  interpreted.

**Out of scope**

- Malware or another process already running as your user with access to your Keychain or files.
- What model providers do with the prompts you send them (see their terms and the README).
- Compromise of the `claude` CLI or of provider APIs themselves.
- Gatekeeper warnings: releases are signed with a self-signed project certificate and are not
  notarized. Verify downloads with `SHA256SUMS.txt` from the release page.
- `npm start` development mode, which deliberately runs without a token and reads keys from `.env`.
