using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security.Principal;
using System.Threading;
using System.Web.Script.Serialization;

namespace TunAssist
{
    public sealed class SafetyStatus { public bool Known { get; set; } public string[] Risks { get; set; } }
    public sealed class SnapshotStatus { public string State { get; set; } public bool Known { get; set; } public bool? Present { get; set; } public bool? Valid { get; set; } public string Message { get; set; } public string Reason { get; set; } }
    public sealed class AdapterStatus
    {
        public string InterfaceGuid { get; set; } public string InterfaceAlias { get; set; }
        public string Description { get; set; } public int InterfaceIndex { get; set; }
        public string Status { get; set; } public bool PhysicalEligible { get; set; }
        public string EligibilityMessage { get; set; } public bool HasDefaultRoute { get; set; }
        public bool DefaultRouteKnown { get; set; } public string Forwarding { get; set; }
        public string ForwardingReadError { get; set; } public string DefaultRouteReadError { get; set; }
        public SnapshotStatus Snapshot { get; set; } public bool CanFix { get; set; } public bool CanRestore { get; set; }
        public string DisplayName { get { return InterfaceAlias + "  ·  " + Localization.T(Status); } }
    }
    public sealed class StatusResult
    {
        public int SchemaVersion { get; set; } public bool Success { get; set; } public string Message { get; set; }
        public bool IsAdministrator { get; set; } public string CheckedAtUtc { get; set; }
        public SafetyStatus Safety { get; set; } public AdapterStatus[] Adapters { get; set; } public string[] Messages { get; set; }
    }
    public sealed class ActionResult
    {
        public int SchemaVersion { get; set; } public bool Success { get; set; } public string Message { get; set; }
        public string[] Messages { get; set; } public bool RollbackFailed { get; set; }
    }
    public sealed class EngineClient
    {
        private readonly bool demo;
        private StatusResult demoStatus;
        public EngineClient(bool demoMode) { demo = demoMode; if (demo) demoStatus = DemoStatus(); }
        public static bool IsAdministrator()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        public static string Resource(string name)
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (stream == null) throw new InvalidOperationException("Embedded resource is missing: " + name);
                using (StreamReader reader = new StreamReader(stream)) return reader.ReadToEnd();
            }
        }
        private static void EnsureNoErrors(PowerShell shell)
        {
            if (shell.HadErrors || shell.Streams.Error.Count > 0)
                throw new InvalidOperationException(string.Join(Environment.NewLine, shell.Streams.Error.Select(x => x.ToString()).ToArray()));
        }
        private static Runspace OpenEngine()
        {
            // Use the Windows PowerShell module directory, never the EXE's directory
            // or a per-user module location. This environment change is process-local.
            string systemModules = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules");
            var initial = InitialSessionState.CreateDefault();
            initial.EnvironmentVariables.Add(new SessionStateVariableEntry("PSModulePath", systemModules, "System modules only"));
            Runspace runspace = RunspaceFactory.CreateRunspace(initial);
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.ReuseThread;
            try
            {
                runspace.Open();
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    foreach (string module in new[] { "NetAdapter", "NetTCPIP", "NetNat" })
                    {
                        string manifest = Path.Combine(systemModules, module, module + ".psd1");
                        if (!File.Exists(manifest))
                        {
                            if (module == "NetNat") continue;
                            throw new InvalidOperationException("Required Windows module is unavailable: " + module);
                        }
                        shell.AddCommand("Import-Module").AddParameter("Name", manifest).AddParameter("ErrorAction", "Stop").Invoke();
                        EnsureNoErrors(shell); shell.Commands.Clear(); shell.Streams.Error.Clear();
                    }
                    runspace.SessionStateProxy.SetVariable("PSModuleAutoLoadingPreference", "None");
                    // Fixed trusted resource text only; adapter data is never interpolated.
                    shell.AddScript(Resource("TunAssist.Bridge"), false).Invoke(); EnsureNoErrors(shell);
                    shell.Commands.Clear(); shell.Streams.Error.Clear();
                    shell.AddCommand("Initialize-DesktopEngine").AddParameter("CoreScriptText", Resource("TunAssist.Core")).Invoke(); EnsureNoErrors(shell);
                }
                return runspace;
            }
            catch { runspace.Dispose(); throw; }
        }
        private static T ReadJson<T>(PowerShell shell)
        {
            var rows = shell.Invoke(); EnsureNoErrors(shell);
            if (rows.Count != 1 || !(rows[0].BaseObject is string)) throw new InvalidOperationException("Unexpected engine response. No success can be assumed.");
            var parser = new JavaScriptSerializer { MaxJsonLength = 1048576 };
            T result = parser.Deserialize<T>((string)rows[0].BaseObject);
            if (result == null) throw new InvalidOperationException("Empty engine response.");
            return result;
        }
        public StatusResult ReadStatus()
        {
            if (demo) { demoStatus.CheckedAtUtc = DateTime.UtcNow.ToString("o"); return demoStatus; }
            using (Runspace runspace = OpenEngine()) using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                shell.AddCommand("Invoke-DesktopStatus");
                StatusResult result = ReadJson<StatusResult>(shell);
                if (result.SchemaVersion != 1 || result.Adapters == null || result.Safety == null || result.Safety.Risks == null)
                    throw new InvalidOperationException("Unknown or incomplete status format.");
                return result;
            }
        }
        public ActionResult Execute(string mode, AdapterStatus selected, bool noSharingConfirmed, bool actionConfirmed)
        {
            if (mode != "Fix" && mode != "Restore") throw new InvalidOperationException("Unsupported action.");
            Guid expectedGuid;
            if (selected == null || !Guid.TryParse(selected.InterfaceGuid, out expectedGuid) || expectedGuid == Guid.Empty)
                throw new InvalidOperationException("A valid physical adapter identity is required.");
            if (!actionConfirmed) throw new InvalidOperationException("Action confirmation is missing.");
            if (demo)
            {
                if (mode == "Fix" && noSharingConfirmed && selected.Forwarding == "Enabled")
                { selected.Forwarding = "Disabled"; selected.Snapshot = new SnapshotStatus { State = "Valid", Known = true, Present = true, Valid = true, Message = "Sample recovery record; no file exists." }; }
                else if (mode == "Restore" && selected.Snapshot != null && selected.Snapshot.State == "Valid" && (selected.Forwarding == "Enabled" || noSharingConfirmed))
                { selected.Forwarding = "Enabled"; selected.Snapshot = new SnapshotStatus { State = "Absent", Known = true, Present = false, Message = "No sample recovery record." }; }
                else throw new InvalidOperationException("Demo action refused: confirmation or sample recovery state is missing.");
                return new ActionResult { SchemaVersion = 1, Success = true, Message = "DEMO: simulated " + mode + ". No Windows setting changed.", Messages = new string[0] };
            }
            if (!IsAdministrator()) throw new InvalidOperationException("Close the app, right-click the EXE and choose Run as administrator. No automatic elevation is performed.");
            using (Runspace runspace = OpenEngine()) using (PowerShell shell = PowerShell.Create())
            {
                shell.Runspace = runspace;
                shell.AddCommand("Invoke-DesktopAction")
                    .AddParameter("Mode", mode)
                    .AddParameter("InterfaceGuid", selected.InterfaceGuid)
                    .AddParameter("InterfaceAlias", selected.InterfaceAlias)
                    .AddParameter("ExpectedForwarding", selected.Forwarding)
                    .AddParameter("NoSharingConfirmed", noSharingConfirmed)
                    .AddParameter("ActionConfirmed", actionConfirmed);
                ActionResult result = ReadJson<ActionResult>(shell);
                if (result.SchemaVersion != 1) throw new InvalidOperationException("Unknown action response. Inspect the current state before retrying.");
                return result;
            }
        }
        public static StatusResult DemoStatus()
        {
            return new StatusResult {
                SchemaVersion = 1, Success = true, Message = "DEMO: sample data only.", IsAdministrator = true,
                CheckedAtUtc = DateTime.UtcNow.ToString("o"), Messages = new string[0], Safety = new SafetyStatus { Known = true, Risks = new string[0] },
                Adapters = new[] {
                    new AdapterStatus { InterfaceGuid = "11111111-1111-4111-8111-111111111111", InterfaceAlias = "Wi-Fi", Description = "Sample physical wireless adapter", InterfaceIndex = 8, Status = "Up", PhysicalEligible = true, DefaultRouteKnown = true, HasDefaultRoute = true, Forwarding = "Enabled", Snapshot = new SnapshotStatus { State = "Absent", Known = true, Present = false, Message = "No recovery record exists for this sample adapter." } },
                    new AdapterStatus { InterfaceGuid = "22222222-2222-4222-8222-222222222222", InterfaceAlias = "Ethernet", Description = "Sample physical Ethernet adapter", InterfaceIndex = 12, Status = "Disconnected", PhysicalEligible = true, DefaultRouteKnown = true, HasDefaultRoute = false, Forwarding = "Disabled", Snapshot = new SnapshotStatus { State = "Absent", Known = true, Present = false, Message = "No sample recovery record." } }
                }
            };
        }
    }
}
