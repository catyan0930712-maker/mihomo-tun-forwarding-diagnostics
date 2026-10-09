# TUN Assist — desktop user guide

**Use the single portable EXE.** Version `0.3.0-preview.3` is an unsigned pre-release with seven display languages. English is the default. No separate `.cmd` launcher or manually downloaded script is needed to use the desktop app.

The connected-link icon appears on the EXE, window and sidebar. This is a cosmetic branding update; the forwarding, protection, recovery and language controls behave as before.

Intended environment: Windows 10/11 x64, .NET Framework 4.8 and the built-in Windows PowerShell 5.1. The app uses PowerShell internally. Portable distribution does not mean stateless operation: a local language preference and protected recovery snapshots may be created.

## What it is for

TUN Assist helps inspect one possible cause of a Windows Mihomo / Clash Verge Rev TUN failure: IPv4 packet forwarding on the physical internet adapter. It shows the current state and offers a narrowly scoped, confirmed workaround with a saved original value.

It is independent of Clash. It does not start or stop Clash, choose proxy nodes, change subscriptions or edit TUN, DNS or routing rules. You manage Clash and verify your actual traffic yourself. Turning IPv4 packet forwarding off does not disable the IPv4 protocol or the adapter.

## Why this project exists

On one Windows host, system-proxy access worked while TUN produced widespread timeouts. Stack changes, a DNS override and explicit WLAN binding did not restore consistent access. The user manually disabled IPv4 forwarding on the physical WLAN adapter, and access recovered. Automatic outlet selection and Mips then worked too.

That was a manual observation, not a test of this desktop app. There is no measured performance improvement, complete same-host A/B/A/B experiment or confirmed reboot-persistence result. The [validation record](../docs/VALIDATION.md) separates that observation from current app checks.

## Use the dashboard

1. Open `TunAssist.exe` normally and use **Refresh status** in **Overview**. Select your actual physical Wi-Fi or Ethernet outlet. Viewing is read-only; the app does not request elevation automatically.
2. Read **IPv4 packet forwarding**, the adapter role, **Recovery snapshot**, sharing protection and the scan time. The role distinguishes an active physical outlet with a default route from a connected adapter without one or a disconnected adapter's stored setting. `Unknown` is not the same as Disabled or Absent; inspect the reported read-failure reason. Snapshot status may ask for administrator access when protected storage cannot be inspected; that does not mean a record is absent.
3. If a network change is appropriate, close the normal instance and explicitly choose **Run as administrator** yourself. Before selecting a physical outlet for a change, turn TUN off manually. Review the adapter identity and protection results again.

The forwarding control shows Enabled, Disabled or Unknown. It describes Windows packet forwarding, not whether TUN or Wi-Fi is on.

| State | Appropriate next action |
| --- | --- |
| Enabled, no recovery record, and the failure matches this workaround | Review the safety conditions before **Apply candidate workaround** |
| Enabled with a valid recovery snapshot | **Restore original setting** can confirm the original value and clear the record without changing forwarding |
| Disabled with a valid recovery snapshot | **Restore original setting** can recover the saved value |
| Disabled without a usable snapshot | Keep the current state; the app cannot infer its history |
| Unknown or a protected topology | Leave network writes blocked and investigate the status |

Use **How it works** for the built-in explanation, **Activity** for operation results and **About** for version information. **Copy session notes** copies Activity text only when you choose it; redact local identifiers before sharing. Confirm the selected alias, GUID and index belong to the intended physical adapter before an action.

## Display language

Open the separate **Language** page from the left navigation. Choose English, Japanese, Simplified Chinese, Malay, Italian, German or Russian. Navigation, status explanations, the guide and confirmation dialogs change immediately. Public repository documentation remains in English.

Changing language only changes the interface. Adapter names, identifiers and required confirmation words such as `NO-SHARING`, `FIX` and `RESTORE` remain unchanged. System and engine messages stay as reported.

In a normal, non-administrator live session, the app saves only the display-language preference to `%LocalAppData%\TunAssist\language.txt`. Administrator and demo sessions do not save this preference; their language selection applies only to that session. A preference-save failure does not authorize or perform a network change.

## Confirmed changes and recovery

Network actions require an administrator, a positive physical-adapter identity and safe sharing/routing inspection. In the confirmation dialog, confirm that TUN is off and no client depends on sharing or subnet routing, then enter `NO-SHARING` and `FIX` or `RESTORE` as requested. Cancelling leaves the operation unconfirmed.

Unknown ICS, sharing/routing services, NAT, bridges or machine-wide routing block network writes. Do not stop services, remove NAT or disable protections just to make the preview allow a test. Third-party forwarding dependencies still require your own topology review.

Before a change, the engine saves and verifies the original forwarding value. **Restore original setting** uses that saved value; it is not a general-purpose Enable switch. It may resolve the same physical adapter when offline or without a default route. If the original value is already active, Restore verifies it again and offers recovery-record cleanup with `RESTORE` confirmation only. This cleanup does not write the network and does not require the no-sharing confirmation.

Snapshots are machine-scoped at `%ProgramData%\MihomoTunForwardingToolkit\Snapshots-v2`, with SYSTEM/Administrators permissions and Windows DPAPI protection. They survive closing or moving the EXE. Existing records are not overwritten; old user-directory JSON is not automatically imported. Records older than 30 days, more than five minutes in the future, corrupt or belonging to another machine/interface require review.

Failed writes or verification trigger an attempted return to the value before the operation. If recovery cannot be verified, the app reports failure and retains the snapshot. Keep the app open while work is running. Power loss, forced termination or a disappearing adapter can prevent compensation. Stop repeating changes after a failed recovery and review the retained record locally.

## Validation and limits

The user reported that `0.3.0-preview.2` passed their testing without identifying individual live Fix/Restore actions. The new `0.3.0-preview.3` binary contains the icon and public-release wording update; that earlier report is not a user test of this exact build. Automated fixture checks and prior read-only application results are recorded in [Validation](../docs/VALIDATION.md). Actual Windows writes, privileged DPAPI/ACL storage, compensation and end-to-end GUI/TUN recovery remain unverified.

Start with the [read-only test plan](TESTING.md). If your network already works with forwarding Disabled, do not turn it back on solely to test the toggle. Passing tests does not establish a universal repair or uninterrupted recovery.

The EXE is unsigned. If Windows prevents launch, stop and report the message. This guide does not ask you to change Windows security settings.

## Build from source, if needed

End users only need the EXE. To build it locally, use **64-bit Windows PowerShell 5.1** (`powershell.exe`), not PowerShell 7. From the project root:

```powershell
powershell.exe -NoProfile -File .\desktop\Build.ps1 -OutputDirectory .\outputs -IntermediateDirectory .\build\desktop
```

The result is the single `outputs\TunAssist.exe`; `build\desktop` contains compiler intermediates. The build uses the Windows .NET Framework compiler and references the installed Windows PowerShell `System.Management.Automation` assembly, version 3. It requires no NuGet restore or copied DLLs. The interface, seven language catalogs, safety engine, bridge, license and notice are embedded resources. At runtime, the app hosts Windows PowerShell in process using the system installation.

Optional modes use sample data and do not inspect or change Windows network settings:

```powershell
.\outputs\TunAssist.exe --demo
.\outputs\TunAssist.exe --self-test .\outputs\desktop-self-test.log
.\outputs\TunAssist.exe --render-demo .\outputs\desktop-demo.png
```

`--demo` opens a simulated interface. `--self-test` runs isolated checks and writes a local log. `--render-demo` writes a sample-interface PNG. Give log and PNG paths an existing writable parent directory. These modes do not establish live Fix/Restore integration; start the EXE without arguments only when you intend to inspect the actual host.

[Testing](TESTING.md) · [Notice](NOTICE.md) · [Project security](../SECURITY.md)
