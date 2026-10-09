# Security

TUN Assist `0.3.0-preview.3` is an unsigned, unofficial Windows pre-release. It inspects a possible IPv4-forwarding factor in Mihomo / Clash TUN failures. It does not establish a universal fix or provide a cloud service.

## Network operations

Startup, Refresh and the CLI's default Diagnose mode are read-only. The app never elevates itself. A network action requires an administrator instance opened by the user, a positively identified physical adapter, fresh identity and state checks, and explicit confirmation.

The only network property changed is one physical interface's IPv4 packet forwarding in `ActiveStore`. IPv4/IPv6 enablement, adapter availability, IP addresses, DNS, firewalls, routes, Windows proxy settings, ICS topology, subscriptions and Clash configuration are outside its controls. Reboot persistence has not been established.

Fix requires an Up physical interface with a known IPv4 default route. Restore requires a valid saved original for the same machine and physical interface; that interface may be offline or lack a default route. There is no arbitrary Enable operation. Adapter names and GUIDs are passed as parameter data, never executable PowerShell text.

Network writes are refused when sharing inspection is incomplete, ICS is active, sharing/hotspot/routing services are not stopped, or a Windows NAT, bridge or machine-wide routing configuration is detected. A running service alone does not prove active ICS, but the refusal is intentionally conservative. Do not stop services or remove configuration to bypass it. Third-party subnet-routing dependencies cannot all be detected, so a manual topology review remains necessary.

The user must acknowledge that TUN is off and no downstream client depends on forwarding, then enter the exact `NO-SHARING` and `FIX` or `RESTORE` words. Confirmation cannot override Unknown. A successful read-back verifies a Windows setting, not TUN connectivity; verify actual traffic separately in Clash.

## Recovery

Before changing forwarding, the engine creates and verifies an immutable pre-change snapshot under `%ProgramData%\MihomoTunForwardingToolkit\Snapshots-v2`. Windows DPAPI LocalMachine protects its contents, and access is restricted to SYSTEM/Administrators. Existing records are not overwritten. Closing, moving or deleting the EXE does not restore the network or remove its records.

Restoration checks schema 2, the engine-version format, machine identity, interface GUID, IPv4, an original value of Enabled and a UTC timestamp. Records older than 30 days or more than five minutes in the future are rejected. Unprotected JSON records are not imported automatically. Corrupt, expired or mismatched records require local review; do not edit them to make validation pass. These protections do not defend against an attacker already holding administrator or SYSTEM privileges.

Failed modification or verification triggers an attempt to return to the known value before the operation and verify it. The same physical interface must still be positively identified. A compensating write to Disabled rechecks sharing protections. Unverified recovery is reported as `ROLLBACK FAILED`, and the snapshot remains. Stop repeating changes and arrange local review.

If forwarding already matches the saved original, Restore requires `RESTORE` confirmation and another identity/state check before removing the snapshot. This cleanup writes no network property and needs no no-sharing confirmation. Cancellation preserves the record.

A global mutex serializes the tool's writes, and the UI blocks closing or changing the target while a write runs. Windows provides no atomic transaction across all interface and topology checks. Power loss, forced termination, disappearing hardware, storage damage and provider races can prevent recovery; uninterrupted connectivity is not guaranteed.

## Runtime and privacy

The EXE embeds its interface, seven language catalogs, bridge, safety engine, license and notice. It hosts installed Windows PowerShell 5.1 in process, imports Windows modules from absolute system paths and excludes user module search paths. It downloads no code and performs no telemetry or automatic diagnostic upload.

Language changes affect display text only. Raw provider states, adapter identities and confirmation words remain unchanged. Only an ordinary non-administrator live session saves the allow-listed language code to `%LocalAppData%\TunAssist\language.txt`; administrator and fixture sessions do not save it. Recovery snapshots use separate protected machine storage.

Status and Activity can contain local adapter names, GUIDs, paths and provider messages. Address-shaped diagnostic text is redacted, but this is not complete anonymization. Redact identifiers before sharing; never upload recovery records, subscriptions, credentials or complete interface inventories. Demo, self-test and sample-rendering modes use fixtures and may write only the local output files requested.

## Validation and reporting

The user reported that `0.3.0-preview.2` passed their testing without identifying individual live Fix/Restore actions. The `0.3.0-preview.3` update changes the icon and branding, with no change to network-operation behavior; it is not the exact previously user-tested binary. Automated mocks, compiled fixture checks and prior read-only application inspection are recorded in [Validation](docs/VALIDATION.md). Real administrator storage, provider writes and GUI recovery remain unverified. Read the [user guide](desktop/README.md) and [test plan](desktop/TESTING.md) before a change; a working network should not be deliberately disrupted just to test the switch.

Report sensitive security issues through a private channel designated by the maintainer. Do not put secrets, identifying logs or protected snapshots in a public issue. Include the version, trigger and observed outcome, distinguishing mocks, read-only inspection and actual device-owner-authorized operations.
