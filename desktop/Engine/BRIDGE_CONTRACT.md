# Desktop bridge contract

This is the JSON interface used by TUN Assist `0.3.0-preview.3`. `TunForwarding.Core.psm1` is an exact byte copy of `scripts/TunForwarding.Core.psm1`. The bridge adds UI request binding and read-result projection; it does not replace the core's topology, snapshot, confirmation, mutex or compensation rules.

## Initialization and host requirements

Dot-source the trusted embedded `DesktopBridge.ps1` resource, then call `Initialize-DesktopEngine -CoreScriptText <trusted embedded core resource>`. Initialization defines the module without inspecting adapters or modifying the network. The filesystem fallback is for source-tree development; the production EXE must initialize its embedded core successfully before exposing commands.

Use a clean Windows PowerShell 5.1 runspace, pin `PSModulePath` to the protected Windows system module directory, and serialize requests on that runspace. Do not load profiles or modules from the executable directory or user-controlled paths. The Windows modules are operating-system dependencies rather than bundled third-party downloads. Do not recreate the production backend concurrently with an active operation.

Call functions with `PowerShell.AddCommand(...).AddParameter(...)`; adapter names, GUIDs and confirmation data must never be interpolated into PowerShell source. The application stays `asInvoker` and performs no UAC relaunch. The user opens it as administrator when intending to perform a confirmed action.

Every public status/action invocation returns exactly one compressed JSON string on the success-output stream. Information, host, warning, verbose and debug messages are collected in `Messages`. An invocation failure becomes `Success: false` with a readable `Message`; an individual property-read failure can leave the status projection successful while that property is Unknown with its own diagnostic. The host must also inspect PowerShell's error state for initialization or parameter-binding failures.

`-Backend <hashtable>` is the isolated-test injection point. Tests inject all backend operations and never construct the production Windows backend.

## Status

`Invoke-DesktopStatus [-Backend <full fake backend>]`

| JSON property | Type | Meaning |
| --- | --- | --- |
| `SchemaVersion` | integer | `1` |
| `Success` | boolean | Whether the status projection completed |
| `Message` | string | Summary or failure text |
| `IsAdministrator` | boolean | False also when privilege inspection is unavailable |
| `CheckedAtUtc` | string | UTC timestamp in round-trip `o` format |
| `Safety.Known` | boolean | Whether sharing/routing inspection completed |
| `Safety.Risks` | string array | Protected-topology or inspection findings |
| `Adapters` | adapter array | Current interfaces; never null |
| `Messages` | string array | Captured messages; never null |

Each adapter contains:

| JSON property | Type | Meaning |
| --- | --- | --- |
| `InterfaceGuid` | string | Canonical GUID, or empty when invalid |
| `InterfaceAlias` | string | Exact current name; use it verbatim as parameter data |
| `Description` | string | Adapter description |
| `InterfaceIndex` | integer | Current index |
| `Status` | string | Provider status, such as `Up` or `Disconnected` |
| `PhysicalEligible` | boolean | Core positively identifies physical non-virtual hardware |
| `EligibilityMessage` | string | Physical eligibility explanation |
| `HasDefaultRoute` | boolean | An IPv4 default route uses this index |
| `DefaultRouteKnown` | boolean | When false, route presence is unknown and Fix is unavailable; Restore does not require a default route |
| `DefaultRouteReadError` | string | Address-redacted provider failure, or empty on a successful route read |
| `Forwarding` | string | `Enabled`, `Disabled` or `Unknown` |
| `ForwardingReadError` | string | Address-redacted provider/validation failure, or empty on a successful read |
| `Snapshot` | snapshot object | Presence and trust are separate findings |
| `CanFix` | boolean | Current read-only readiness hint |
| `CanRestore` | boolean | Current read-only readiness hint, including confirmed cleanup |

Snapshot properties are `State` (`Absent`, `Valid`, `Invalid`, `Unknown`), `Known` (boolean), `Present` (nullable boolean), `Valid` (nullable boolean), `Reason` (string), and `Message` (string). `Absent` is known with `Present: false` and `Valid: null`; `Invalid` is known and present with `Valid: false`. `Unknown` has `Known: false`, `Present: null` and `Valid: null`. A non-administrator scan does not read protected snapshots and reports Unknown. Presence alone never enables Restore.

Reason codes distinguish `AdministratorRequired`, `AdministratorStatusUnavailable`, `MachineIdentityUnavailable`, `AdapterIdentityUnavailable`, `ReadFailed`, `ValidationFailed`, `NoSnapshot` and `Validated`. Messages explain the reason without projecting machine identity or snapshot contents. Route/sharing query exceptions retain their reported diagnostic reason. If the core returns only `ICS inspection unavailable`, the bridge explicitly says no exception detail was returned; it does not infer active sharing or invent an HRESULT.

The desktop localizes display strings only. Model states, aliases, GUIDs, expected forwarding values and typed confirmation words remain unchanged when the user selects another language.

No machine identifier, snapshot contents, route next hop or IP-address field is projected. Diagnostic messages redact address-shaped text. Adapter aliases and GUIDs remain local identifiers; do not publish raw status output.

Readiness hints are advisory. Actions freshly re-evaluate identity, state and the core safeguards; a previously enabled button is not authorization to bypass a changed condition.

## Actions

`Invoke-DesktopAction -Mode Fix|Restore -InterfaceGuid <selected GUID> -InterfaceAlias <exact selected name> -ExpectedForwarding Enabled|Disabled -NoSharingConfirmed <Boolean> -ActionConfirmed <Boolean> [-Backend <full fake backend>]`

The UI sets confirmation booleans only after the user enters the exact displayed words. `ActionConfirmed` must be an actual Boolean true; strings such as `"true"` or `"false"` are rejected. `NoSharingConfirmed` must also be an actual Boolean and must be true whenever the core requests `NO-SHARING`. The already-original Restore cleanup path retains the core's `RESTORE`-only confirmation rule because it writes no network property.

Both GUID and alias must resolve uniquely to the same currently eligible physical interface. Fresh resolution happens throughout the operation and before writes or snapshot deletion. A replacement adapter, renamed alias, duplicate identity/name or a Forwarding value different from the displayed `ExpectedForwarding` refuses the request. A new index for the same GUID/name is resolved rather than trusted from the UI. After the first mutation attempt, the core controls verification and compensation using the operation's pre-change value.

Only already-administrator actions are accepted. The bridge never invokes the console backend's `Read-Host` confirmation or elevates. Original core requirements for physical hardware, Fix Up/default route, topology, snapshots, rollback and Restore remain in force.

Action JSON contains `SchemaVersion` (integer `1`), `Success` (boolean), `Message` (string), `Messages` (string array, never null), and `RollbackFailed` (boolean). `Success: true` verifies a setting or snapshot cleanup; it does not establish TUN connectivity. On `RollbackFailed: true`, retain the snapshot, stop retrying and arrange local review. Refresh read-only status after an action; do not repeat it automatically.
