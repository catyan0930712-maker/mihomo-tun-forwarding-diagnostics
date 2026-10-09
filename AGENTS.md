# Contributor instructions

Read `README.md`, `SECURITY.md`, `desktop/README.md`, `desktop/Engine/BRIDGE_CONTRACT.md` and `docs/VALIDATION.md` before changing the project.

## Safety boundaries

- Treat this as an unofficial candidate troubleshooting tool, not a universal TUN repair.
- Default to read-only diagnosis. Do not run real adapter, ICS, routing, firewall or DNS modifications without separate, explicit device-owner permission. Prefer the fully injected fake backends.
- Preserve refusal for unknown or protected topology. Confirmation words must not bypass failed inspection. Do not disable services, remove NAT or change topology to make a test pass.
- Restrict network changes to one positively identified physical adapter's IPv4 forwarding in ActiveStore. Keep GUID, exact alias and displayed prior-state binding, fresh resolution, protected snapshots, locking, verification and compensation.
- Preserve read-only startup, `asInvoker`, no automatic UAC, no arbitrary Enable action and the in-progress write/close guard.
- Keep network-provider states, identities and confirmation words as raw data. Localization may change display text only; `NO-SHARING`, `FIX` and `RESTORE` stay exact.
- Do not upload subscriptions, credentials, proxy nodes, protected snapshots, machine identifiers or identifying screenshots/logs. Public documentation is in English; the seven UI languages, including Chinese, are intentional resources.

## Development and validation

Maintain compatibility with Windows PowerShell 5.1, UTF-8 paths and localized adapter names. The desktop build targets .NET Framework 4.8 x64 and hosts the installed Windows PowerShell runtime; do not add automatic downloads or user-controlled executable-script resolution.

Use `tests/ParsePowerShell.ps1`, `tests/Run-MockTests.ps1`, `desktop/tests/Bridge.Tests.ps1` and `desktop/tests/Localization.Tests.ps1` in both Windows PowerShell 5.1 and PowerShell 7. Run compiled desktop self-tests and `desktop/tests/Desktop.Safety.Tests.ps1 -ExecutablePath <built EXE>` under the required Windows runtime. Build into ignored or external output directories. Regenerate and verify `MANIFEST.sha256` only after all source/documentation edits are final.

Tests must inject every network/storage operation and retain real-system-command tripwires. Source parsing, fixtures and read-only inspection are distinct from real network-write integration. Never claim an unexecuted test passed; mark missing coverage as not tested.

Review the failure and recovery paths before altering an operation. A reported rollback failure must retain evidence and block repeated writes. Do not modify snapshots to satisfy validation. Document behavioral changes, executed checks and remaining limitations together.

Release an executable only when its corresponding source/resources and checks have been reviewed. Keep published hashes aligned with the actual files. Public publication and live fault-injection experiments require their own explicit authorization.
