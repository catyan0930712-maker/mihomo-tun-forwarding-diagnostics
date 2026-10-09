# Validation of TUN Assist 0.3.0-preview.3

This record distinguishes automated fixtures, read-only Windows inspection and user reports. A missing test is not a pass or a failure. The app remains an unsigned pre-release.

## Current evidence

The user reported that `0.3.0-preview.2` passed their testing. The report did not identify individual live Fix/Restore, snapshot-storage or fault-recovery actions, so those are not recorded as verified operations.

The `0.3.0-preview.3` release updates the connected-link icon on the EXE, window and sidebar, plus public-release wording. These changes are cosmetic and do not alter forwarding, protection, recovery or language behavior. Publication was approved for this update, but the prior report does not establish user testing of this exact rebuilt binary.

The originating workaround was a separate manual observation: on one Windows host, system-proxy access worked while TUN timed out; the user disabled physical WLAN IPv4 forwarding and access returned. Automatic outlet selection and Mips subsequently worked. This supports investigating forwarding in a suitable case, not a universal cause, a measured speed improvement or successful GUI network-write integration.

## Executed automated checks

The following checks passed for the final `0.3.0-preview.3` source and rebuilt executable on October 10, 2026.

| Check | Result | Scope |
| --- | --- | --- |
| Safety-core fake backend | 109 passed in Windows PowerShell 5.1.26100.9587; 109 in PowerShell 7.6.5 | Network, confirmation and storage operations simulated; zero real system commands |
| Desktop bridge fake backend | 42 passed in each engine | Typed confirmations, GUID/alias/state binding, refusals, compensation, read-error propagation and snapshot reasons; real commands tripwired |
| Localization resources | 28 passed in each engine | Seven strict UTF-8 catalogs; exact keys, nonempty strings, format placeholders and literal confirmation words |
| Compiled EXE self-tests | 91 passed | Policy/demo state, actual WPF navigation/confirmation events, failed-scan cache clearing and seven-language display/guard checks; no live backend |
| Final EXE source/resource safety checks | 25 passed | Static parsing and reflection only; embedded core, bridge, XAML, languages, license and notice match source; asInvoker and Windows PowerShell assembly reference verified |
| Offline WPF rendering | 21 images across Overview, Language and About in seven languages | Fixture data only; representative English, Japanese and Russian layouts reviewed |
| Application icon packaging | Embedded PNG matches the source; window/sidebar icons present in all seven languages; shell icon extracted from the EXE | Fixed embedded resource, seven ICO sizes from 16 to 256 pixels, no external runtime image file |

Earlier preview.2 read-only application results agreed with independent Windows inspection: Ethernet was Disconnected/Enabled and WLAN Up/Disabled. Protected snapshots needed administrator access; incomplete sharing inspection kept actions blocked. An ICS method probe returned E_ACCESSDENIED, rather than establishing that sharing was absent. These live read-only observations were not repeated for the cosmetic icon build.

These are repeated executions of the same scenarios in two engines, not independent network experiments. Mocks exercise recovery logic and simulated ACL objects; they do not validate the real Windows providers or protected storage.

For the local preview.3 rerun, Windows PowerShell 5.1 has a Restricted execution-policy default. Its checks load the exact reviewed source AST in memory, preserving `PSScriptRoot`, and load the same core/bridge definitions with the same assertions, injected backends and real-command tripwires. PowerShell 7 runs the ordinary test files. No execution-policy setting is changed. GitHub's Windows runner uses the standard file-based test entry points. This test-loader difference does not change the application runtime or establish live network integration.

The final checked preview.3 executable is **381,952 bytes** (373 KiB), SHA256:

```text
64e5d1c26a3b1c75a0e389dbe26dfb4f93d8cb0520807bfd03648663d2160c29
```

The shared safety-core source, desktop copy and embedded core remain byte-identical. Source-package integrity is checked separately by `MANIFEST.sha256`; a hash is not a signature or publisher authentication.

The updated EXE is a new build with the selected connected-link branding and an embedded public pre-release notice. The prior user's preview.2 acceptance is separate from this build's automated validation. Neither an icon update nor publication approval establishes real network-write integration.

## Reproduce the isolated checks

From the repository root, run the following with Windows PowerShell 5.1, and repeat the first four with PowerShell 7:

```powershell
powershell.exe -NoProfile -File .\tests\ParsePowerShell.ps1
powershell.exe -NoProfile -File .\tests\Run-MockTests.ps1
powershell.exe -NoProfile -File .\desktop\tests\Bridge.Tests.ps1
powershell.exe -NoProfile -File .\desktop\tests\Localization.Tests.ps1
powershell.exe -NoProfile -File .\tests\VerifyManifest.ps1
powershell.exe -NoProfile -File .\desktop\Build.ps1 -OutputDirectory .\outputs -IntermediateDirectory .\build\desktop
.\outputs\TunAssist.exe --self-test .\outputs\desktop-self-test.log
powershell.exe -NoProfile -File .\desktop\tests\Desktop.Safety.Tests.ps1 -ExecutablePath .\outputs\TunAssist.exe
```

Build outputs are ignored. Run manifest verification on the clean source package before creating outputs inside it, because the verifier checks every package file. The workflows use runner temporary storage and run isolated checks; they do not upload an executable, publish a release or run the production network backend. Current remote workflow results must be evaluated from their own run; no remote pass is inferred from local results.

## Remaining integration work

The development agent performed no real network-setting writes. The following are not established for the desktop app:

- Administrator DPAPI/ACL creation, durable read-back and cross-administrator recovery on a real machine.
- Actual Windows Fix/Restore provider writes, failure compensation, interrupted-operation recovery and live snapshot cleanup.
- End-to-end GUI/TUN recovery, dedicated IPv4 TCP/UDP and IPv6 checks, sharing-client safety and broad Windows 10/11 compatibility.
- Restart, sleep/wake or network-switch behavior; complete controlled same-host comparisons; numerical latency/throughput improvements.

Deliberate fault injection belongs on a separately authorized, recoverable test machine with no downstream sharing/routing dependency. Do not disturb a working host to make a checklist complete. The [user test plan](../desktop/TESTING.md) provides bounded read-only and optional authorized checks.
