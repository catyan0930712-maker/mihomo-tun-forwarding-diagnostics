# Contributing

Changes to diagnostics, translations and recovery coverage are welcome. Read [Security](SECURITY.md) and [Contributor instructions](AGENTS.md), use injected fake backends, and explain the final behavior and relevant validation in a contribution.

## Useful reports

Describe the version, Windows build, connection type and selected physical outlet. Record the actual forwarding, recovery and sharing-protection states, any reported read failure, the TUN/system-proxy comparison and actual website/application results. A node-latency Timeout alone does not establish a connectivity failure.

Identify whether a result came from a user-performed manual operation, a third-party report, a repository mock, a read-only inspection or a real authorized network change. Keep before/after settings and timestamps clear; mark anything not performed as not tested. Counterexamples are useful, including TUN failing with forwarding Disabled or working with it Enabled.

Do not create a fault on a recovered production network merely to complete a report. A live change requires separate permission, no sharing/subnet dependency, local access and a recovery path. Do not bypass an Unknown result or remove protected recovery evidence.

## Privacy

Redact private aliases, GUIDs, addresses, host/user names and directory paths from logs and screenshots. Do not upload subscriptions, authentication data, proxy-node addresses, complete interface inventories or recovery snapshots. Use a designated private channel for sensitive security reports.

## Tests and translations

Run the appropriate source, fake-backend, language-resource and desktop checks described in [Validation](docs/VALIDATION.md). Tests must not query or modify real network interfaces. Fixture checks do not establish live Windows recovery or TUN performance.

Keep the English resource key set, nonempty translations and format placeholders consistent across all seven catalogs. Translate explanations and labels, while preserving literal `NO-SHARING`, `FIX` and `RESTORE` confirmation words and raw provider data. Public repository documentation remains in English.
