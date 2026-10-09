# Testing TUN Assist 0.3.0-preview.3

Start with read-only checks. Any live network action requires the device owner's separate, explicit decision, a safe topology and a recovery path. Do not deliberately disturb a working host just to exercise the controls.

For a source build, follow [the build instructions](README.md#build-from-source-if-needed). `--demo` uses fixtures; its displayed values and simulated changes say nothing about the workstation. `--self-test <log>` and `--render-demo <png>` also use isolated sample data. Their logs and screenshots are local artifacts, not evidence of live network recovery.

## 1. Start with read-only checks

Open the single `TunAssist.exe` normally. If Windows blocks launch, record the message and stop; do not change security settings to follow this plan.

- Confirm the title/version, default English text and layout are readable at the display scaling you normally use.
- Check that the connected-link icon appears consistently on the EXE, window and sidebar. An icon or layout check does not exercise network changes.
- Select the actual physical Wi-Fi or Ethernet outlet in **Overview** and use **Refresh status**. Record Enabled, Disabled or Unknown, the adapter role, scan time, recovery-snapshot status and sharing-protection result.
- Confirm a scan does not request elevation or change forwarding. It should not start/stop Clash or change its settings.
- Open **How it works**, **Activity** and **About**. Check that the guide explains packet forwarding, the limited workaround, confirmation and recovery.
- When a value or safety result is Unknown, confirm the app presents that uncertainty and available read-failure reasons rather than treating it as a safe Disabled/Absent state. Do not deliberately induce a failure on the working host.
- Confirm network actions are unavailable without the required privileges or safe conditions. A normal user may not be able to inspect protected snapshot storage; an administrator-access prompt must not be shown as a known absent record.

Use the left-side **Language** page to check English, Japanese, Simplified Chinese, Malay, Italian, German and Russian. Check navigation, state explanations, the guide, and any confirmation dialog you open without confirming a network action. Text should remain readable and controls visible. Switching language must not change the selected adapter, forwarding state, protection results or action eligibility; confirmation words and identifiers remain exact.

In a normal, non-administrator live session, change the language, close and reopen the app, and check the saved selection. The preference is `%LocalAppData%\TunAssist\language.txt`. Administrator and demo sessions must not save language changes. These checks do not require a network write.

If deeper status inspection is needed, the user may independently reopen the app with **Run as administrator** and repeat **Refresh status** only. Administrator privileges alone are not confirmation for a network write.

## 2. Decide whether a live change is appropriate

Do not create a fault just to exercise the interface. In particular, an already-working host with forwarding Disabled and no app snapshot does not need a test Enable operation. This app cannot know the state before an old manual change.

A live action should only be considered when the user explicitly chooses it, the reported failure fits this workaround and all of these are true:

- The chosen adapter is the real physical outlet; TUN has been turned off manually for selection.
- The host is not supplying ICS, Mobile Hotspot, bridging, subnet routing or a connection another device depends on.
- Safety inspection is complete and permits the action. NAT or service-related refusal is a result to report, not a setting to bypass.
- Local access and a recovery path remain available if connectivity is interrupted. The host is not being tested through its only remote link.

Use a separate recoverable test machine or adapter for deliberate write-failure, restart or outage experiments. Those experiments require their own permission and are not routine smoke tests on a recovered production host.

## 3. Optional user-performed Disable test

Only the user should perform this after deciding a live change is appropriate.

1. Open the app as administrator, refresh and verify the exact selected adapter and Enabled state.
2. Choose **Apply candidate workaround**. Read the confirmation, check the TUN-off and no-sharing statements, and enter `NO-SHARING` and `FIX` as requested. Cancelling is a useful non-writing check; do not confirm unless ready for the change.
3. Wait for completion without forcing the app or worker to stop. Record the Activity result, final forwarding state and recovery-record availability. Reading Disabled verifies a property, not TUN connectivity.
4. Manage Clash manually and test the same real websites/apps that previously failed. Record the settings and outcome; a node-test Timeout indicator alone is insufficient.

Do not repeat Disable after an error or manually remove a snapshot to unblock it. Preserve a failed operation's record for review.

## 4. Optional user-performed Restore test

Restore requires a valid saved original state for the same machine and physical interface.

1. Review the record and selected interface in an administrator instance.
2. Choose **Restore original setting** and make only the confirmations requested for that action. A restore that writes the network requires the no-sharing and action confirmations.
3. Wait for the result. Confirm the saved original value was restored and that successful restore removed the recovery record. Restore does not guarantee that the original TUN fault will stay resolved.
4. If the original value is already active, confirmed record cleanup is a no-network-write case. Cancellation must preserve the record.

If compensation or restore is reported as failed, stop repeating actions and keep the snapshot. Do not guess a value, edit identifiers/timestamps or disable protective services to make recovery pass.

## 5. Report observations

Use this short record; leave anything not performed as **Not tested**.

| Item | Result |
| --- | --- |
| Preview version, Windows build, display scaling | |
| Normal launch and read-only refresh | |
| Selected adapter role, forwarding/snapshot/protection states | |
| Language page, translation/layout checks and normal-session persistence | |
| How it works, Activity and About | |
| Administrator read-only refresh, if performed | |
| Cancelled confirmation, if performed | |
| User-performed Disable and actual traffic, if separately chosen | |
| User-performed Restore or record cleanup, if separately chosen | |
| Errors, time and remaining recovery record | |

Redact private aliases, GUIDs, addresses, host/user names and other identifying data from screenshots or Activity text before sharing. Do not send protected snapshots or subscriptions.

## What a successful test establishes

Read-only acceptance confirms that this preview can launch and present the observed state on that host. A user-performed change, if chosen, is one real observation of the corresponding action. Neither establishes a universal TUN fix, all supported Windows configurations, reboot persistence, zero interruption or a measured speed improvement.

Current automated, compiled fixture and read-only results are recorded in [Validation](../docs/VALIDATION.md). They do not count as live network-write integration tests. Even a compiled application's successful read-only scan does not validate Fix/Restore, privileged snapshot storage or TUN traffic. Describe the specific action and outcome rather than treating a general acceptance report as proof of every operation.
