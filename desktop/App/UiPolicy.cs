using System;

namespace TunAssist
{
    public static class UiPolicy
    {
        public static bool Safe(StatusResult state)
        { return state != null && state.Success && state.Safety != null && state.Safety.Known && state.Safety.Risks != null && state.Safety.Risks.Length == 0; }
        public static bool ValidIdentity(AdapterStatus adapter)
        { Guid guid; return adapter != null && adapter.PhysicalEligible && adapter.InterfaceIndex > 0 && Guid.TryParse(adapter.InterfaceGuid, out guid) && guid != Guid.Empty && !string.IsNullOrWhiteSpace(adapter.InterfaceAlias); }
        public static bool HasRecovery(AdapterStatus adapter)
        { return adapter != null && adapter.Snapshot != null && adapter.Snapshot.Known && adapter.Snapshot.State == "Valid" && adapter.Snapshot.Present == true && adapter.Snapshot.Valid == true; }
        public static bool CanFix(StatusResult state, AdapterStatus adapter)
        { return Safe(state) && state.IsAdministrator && ValidIdentity(adapter) && adapter.Status == "Up" && adapter.DefaultRouteKnown && adapter.HasDefaultRoute && adapter.Forwarding == "Enabled" && adapter.Snapshot != null && adapter.Snapshot.Known && adapter.Snapshot.State == "Absent" && adapter.Snapshot.Present == false; }
        public static bool CanRestore(StatusResult state, AdapterStatus adapter)
        { return state != null && state.Success && state.IsAdministrator && ValidIdentity(adapter) && HasRecovery(adapter) && (adapter.Forwarding == "Enabled" || (adapter.Forwarding == "Disabled" && Safe(state))); }
        public static bool IsCleanup(AdapterStatus adapter)
        { return HasRecovery(adapter) && adapter.Forwarding == "Enabled"; }
        public static bool Confirmed(string mode, bool cleanup, bool tunOff, bool noSharing, string topologyWord, string actionWord)
        {
            if (mode != "Fix" && mode != "Restore") return false;
            if (actionWord != mode.ToUpperInvariant()) return false;
            if (cleanup && mode == "Restore") return true;
            return tunOff && noSharing && topologyWord == "NO-SHARING";
        }
    }
}
