using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Versioning;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;

[assembly: AssemblyTitle("TUN Assist")]
[assembly: AssemblyDescription("Local Windows IPv4 forwarding diagnostics and confirmed recovery")]
[assembly: AssemblyProduct("TUN Assist")]
[assembly: AssemblyVersion("0.3.0.0")]
[assembly: AssemblyFileVersion("0.3.0.3")]
[assembly: TargetFramework(".NETFramework,Version=v4.8")]

namespace TunAssist
{
    internal static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            try
            {
                if (args.Length >= 1 && args[0] == "--self-test")
                {
                    string result = SelfTests.Run();
                    if (args.Length == 2) File.WriteAllText(args[1], result, new UTF8Encoding(false));
                    else Console.WriteLine(result);
                    return 0;
                }
                bool render = args.Length >= 1 && args[0] == "--render-demo";
                bool demo = render || (args.Length == 1 && args[0] == "--demo");
                if (!(args.Length == 0 || demo)) throw new InvalidOperationException("Supported options: --demo, --render-demo <png>, --self-test <log>.");
                Localization.Select(demo ? "en" : UserPreferences.Load());
                var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                Window window = (Window)XamlReader.Parse(EngineClient.Resource("TunAssist.Window"));
                var controller = new MainController(window, demo, !render);
                if (render)
                {
                    if (args.Length != 2) throw new InvalidOperationException("--render-demo requires an output PNG path.");
                    FrameworkElement visual = (FrameworkElement)window.Content;
                    visual.Width = 1060; visual.Height = 790;
                    visual.Measure(new Size(1060, 790)); visual.Arrange(new Rect(0, 0, 1060, 790)); visual.UpdateLayout();
                    var bitmap = new RenderTargetBitmap(1060, 790, 96, 96, PixelFormats.Pbgra32); bitmap.Render(visual);
                    var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using (FileStream output = File.Create(args[1])) encoder.Save(output);
                    GC.KeepAlive(controller); return 0;
                }
                Rect available = SystemParameters.WorkArea;
                window.MaxWidth = Math.Max(360, available.Width); window.MaxHeight = Math.Max(360, available.Height);
                window.MinWidth = Math.Min(window.MinWidth, window.MaxWidth); window.MinHeight = Math.Min(window.MinHeight, window.MaxHeight);
                window.Width = Math.Min(window.Width, window.MaxWidth); window.Height = Math.Min(window.Height, window.MaxHeight);
                app.Run(window); GC.KeepAlive(controller); return 0;
            }
            catch (Exception error)
            {
                if (args.Length == 2 && (args[0] == "--self-test" || args[0] == "--render-demo"))
                    File.WriteAllText(args[1] + ".error.txt", error.ToString());
                else MessageBox.Show(error.Message, "TUN Assist could not start", MessageBoxButton.OK, MessageBoxImage.Error);
                return 1;
            }
        }
    }
    internal sealed class MainController
    {
        private readonly Window window;
        private readonly EngineClient engine;
        private readonly bool demo;
        private StatusResult status;
        private bool busy;
        private bool writing;
        private bool manualReview;
        private bool changingLanguage;
        private string currentPage = "Dashboard";
        private string pageTitle = "A clearer view of TUN issues.";
        private string pageSubtitle = "Inspect the setting. Make a considered change. Keep a way back.";
        private readonly StringBuilder activity = new StringBuilder();
        private T Element<T>(string name) where T : FrameworkElement { return (T)window.FindName(name); }
        private AdapterStatus Selected { get { return Element<ComboBox>("AdapterPicker").SelectedItem as AdapterStatus; } }
        private void Text(string name, string value) { Localization.SetText(Element<TextBlock>(name), value ?? ""); }
        private static Brush BrushFor(string color) { return (Brush)new BrushConverter().ConvertFromString(color); }
        public MainController(Window mainWindow, bool demoMode, bool startOnLoad)
        {
            window = mainWindow; demo = demoMode; engine = new EngineClient(demo);
            using (Stream image = Assembly.GetExecutingAssembly().GetManifestResourceStream("TunAssist.Icon"))
            {
                if (image == null) throw new InvalidOperationException("Embedded application icon is missing.");
                BitmapFrame icon = BitmapFrame.Create(image, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                icon.Freeze();
                window.Icon = icon;
                Element<Image>("BrandIcon").Source = icon;
            }
            if (string.IsNullOrEmpty(Localization.Code)) Localization.Select("en");
            Localization.ApplyTree(window);
            Element<Button>("DashboardNav").Click += delegate { Page("Dashboard", "A clearer view of TUN issues.", "Inspect the setting. Make a considered change. Keep a way back."); };
            Element<Button>("GuideNav").Click += delegate { Page("Guide", "A focused tool, explained.", "The purpose, the story and a careful way to use it."); };
            Element<Button>("ActivityNav").Click += delegate { Page("Activity", "Your session notes.", "Local observations and the actual result of each operation."); };
            Element<Button>("AboutNav").Click += delegate { Page("About", "TUN Assist.", "A small Windows companion with a deliberately narrow scope."); };
            Element<Button>("LanguageNav").Click += delegate { Page("Language", "Language", "Choose your display language."); };
            changingLanguage = true;
            Element<ListBox>("LanguagePicker").ItemsSource = Localization.Languages;
            Element<ListBox>("LanguagePicker").SelectedItem = Localization.Languages.First(x => x.Code == Localization.Code);
            changingLanguage = false;
            Element<ListBox>("LanguagePicker").SelectionChanged += delegate { ChangeLanguage(); };
            Element<Button>("RefreshButton").Click += async delegate { await Refresh(); };
            Element<ComboBox>("AdapterPicker").SelectionChanged += delegate { RenderStatus(); };
            Element<Button>("FixButton").Click += async delegate { await Act("Fix"); };
            Element<Button>("RestoreButton").Click += async delegate { await Act("Restore"); };
            Element<Button>("ForwardingSwitch").Click += async delegate { AdapterStatus a = Selected; if (a != null) await Act(a.Forwarding == "Enabled" ? "Fix" : "Restore"); };
            Element<Button>("LicenseButton").Click += delegate { ShowLicense(); };
            Element<Button>("CopyActivityButton").Click += delegate
            {
                try { Clipboard.SetText(activity.ToString()); Text("FooterStatus", "Session notes copied. Redact identifiers before sharing publicly."); }
                catch (Exception e) { Text("FooterStatus", Localization.F("Clipboard unavailable: {0}", e.Message)); }
            };
            window.Closing += Closing;
            Page("Dashboard", "A clearer view of TUN issues.", "Inspect the setting. Make a considered change. Keep a way back.");
            if (demo)
            {
                window.Title = Localization.T("TUN Assist · Demo (no Windows changes)");
                Element<Border>("DemoBanner").Visibility = Visibility.Visible;
                Text("ModeBadge", "DEMO · SAMPLE DATA"); ApplyStatus(engine.ReadStatus()); Note("Demo opened. No live backend is constructed.");
            }
            else
            {
                RenderStatus(); Note("Opened in read-only mode. No network setting changed.");
                if (startOnLoad) window.Loaded += async delegate { await Refresh(); };
            }
        }
        private void Page(string key, string title, string subtitle)
        {
            currentPage = key; pageTitle = title; pageSubtitle = subtitle;
            foreach (string name in new[] { "Dashboard", "Guide", "Activity", "About", "Language" })
            {
                Element<StackPanel>(name + "Page").Visibility = name == key ? Visibility.Visible : Visibility.Collapsed;
                string button = name == "Dashboard" ? "DashboardNav" : name == "Guide" ? "GuideNav" : name + "Nav";
                Element<Button>(button).Background = BrushFor(name == key ? "#EDF6FF" : "#FFFFFF");
                Element<Button>(button).Foreground = BrushFor(name == key ? "#267CC2" : "#738397");
            }
            Text("PageTitle", title); Text("PageSubtitle", subtitle);
            if (key == "Language") Text("LanguagePersistence", !demo && EngineClient.IsAdministrator() ? "In an administrator session, the language applies to this session only." : "Applies immediately and is remembered on this device.");
        }
        private void ChangeLanguage()
        {
            if (changingLanguage || busy || writing) return;
            var choice = Element<ListBox>("LanguagePicker").SelectedItem as LanguageChoice;
            if (choice == null || choice.Code == Localization.Code) return;
            Localization.Select(choice.Code); Localization.ApplyTree(window);
            window.Title = demo ? Localization.T("TUN Assist · Demo (no Windows changes)") : "TUN Assist";
            Element<ComboBox>("AdapterPicker").Items.Refresh();
            RenderStatus(); Page(currentPage, pageTitle, pageSubtitle);
            Text("FooterStatus", "Language changed. Network settings are unchanged.");
            if (!demo)
            {
                try { UserPreferences.Save(choice.Code); }
                catch (Exception error) { Text("FooterStatus", Localization.F("Language changed for this session. Preferences could not be saved: {0}", error.Message)); }
            }
        }
        private void Note(string message)
        {
            activity.AppendLine(DateTime.Now.ToString("HH:mm:ss") + "  " + message).AppendLine();
            Element<TextBox>("ActivityText").Text = activity.ToString();
        }
        private void Result(string message, bool error)
        {
            Element<Border>("ResultBanner").Visibility = Visibility.Visible;
            Element<Border>("ResultBanner").Background = BrushFor(error ? "#FBE9E5" : "#E4F3EB");
            Element<TextBlock>("ResultText").Foreground = BrushFor(error ? "#9D3B2C" : "#266747");
            Text("ResultText", message); Note(message);
        }
        private void SetBusy(bool value, string message)
        {
            busy = value; Element<Button>("RefreshButton").IsEnabled = !value;
            Element<ComboBox>("AdapterPicker").IsEnabled = !value;
            Element<ListBox>("LanguagePicker").IsEnabled = !value;
            RenderStatus(); Text("FooterStatus", message);
        }
        private async Task Refresh()
        {
            if (busy) return;
            SetBusy(true, "Reading Windows state · No network settings are changed");
            try
            {
                StatusResult read = await Task.Run(() => engine.ReadStatus());
                ApplyStatus(read);
                if (read.Success) Note("Read-only status refreshed.");
                else Result(Localization.F("Inspection incomplete: {0} No changes are available.", read.Message), true);
                foreach (string message in read.Messages ?? new string[0]) Note(message);
                Text("FooterStatus", read.Success ? Localization.F("Status refreshed · {0}", Localization.T(read.IsAdministrator ? "Administrator session" : "Read-only session")) : "Inspection incomplete · Changes unavailable");
            }
            catch (Exception error)
            {
                status = null; Element<ComboBox>("AdapterPicker").ItemsSource = null; RenderStatus();
                Result(Localization.F("Could not read the current state: {0} Changes are unavailable.", error.Message), true);
                Text("LastChecked", "Read failed · state unknown"); Text("FooterStatus", "Inspection failed · No network setting changed");
            }
            finally { busy = false; Element<Button>("RefreshButton").IsEnabled = true; Element<ComboBox>("AdapterPicker").IsEnabled = true; Element<ListBox>("LanguagePicker").IsEnabled = true; RenderStatus(); }
        }
        private void ApplyStatus(StatusResult read)
        {
            string previous = Selected == null ? null : Selected.InterfaceGuid;
            status = read;
            AdapterStatus[] adapters = read.Success ? (read.Adapters ?? new AdapterStatus[0]).Where(a => a.PhysicalEligible).ToArray() : new AdapterStatus[0];
            Element<ComboBox>("AdapterPicker").ItemsSource = adapters;
            AdapterStatus chosen = adapters.FirstOrDefault(a => a.InterfaceGuid == previous) ?? adapters.FirstOrDefault(a => a.Status == "Up" && a.HasDefaultRoute) ?? adapters.FirstOrDefault();
            Element<ComboBox>("AdapterPicker").SelectedItem = chosen;
            DateTime checkedUtc;
            Text("LastChecked", DateTime.TryParse(read.CheckedAtUtc, out checkedUtc) ? Localization.F("Checked {0}", checkedUtc.ToLocalTime().ToString("HH:mm:ss")) : "Time unavailable");
            RenderStatus();
        }
        private void RenderStatus()
        {
            AdapterStatus a = Selected;
            bool ready = status != null && status.Success && a != null;
            string forwarding = ready && (a.Forwarding == "Enabled" || a.Forwarding == "Disabled") ? a.Forwarding : "Unknown";
            Text("ForwardingValue", forwarding);
            Element<TextBlock>("ForwardingValue").Foreground = BrushFor(forwarding == "Disabled" ? "#267CC2" : forwarding == "Unknown" ? "#8E6941" : "#213449");
            Text("AdapterCaption", ready ? a.InterfaceAlias + " · " + a.Description : "No eligible physical adapter selected");
            Text("AdapterRole", !ready ? "Windows setting for the selected adapter. This is not TUN on/off." : a.Status == "Disconnected" ? "Disconnected adapter · Stored setting only" : !a.DefaultRouteKnown ? "Route inspection unavailable" : a.Status == "Up" && a.HasDefaultRoute ? "Active physical outlet · IPv4 default route" : a.Status == "Up" ? "Connected adapter · No IPv4 default route" : "Selected adapter · Not an active internet outlet");
            Text("StateExplanation", forwarding == "Enabled" ? "Windows can forward IPv4 packets between interfaces. This may be relevant when system proxy access works but TUN fails." : forwarding == "Disabled" ? "IPv4 packet forwarding is off on this adapter. IPv4 and Wi-Fi are not disabled. This does not confirm TUN connectivity." : "The current forwarding state is unknown. A failed inspection never enables a change.");
            if (forwarding == "Unknown" && ready && !string.IsNullOrEmpty(a.ForwardingReadError))
                Text("StateExplanation", Localization.T("The current forwarding state is unknown. A failed inspection never enables a change.") + "\n" + Localization.F("Forwarding read failed: {0}", a.ForwardingReadError));
            Element<Button>("ForwardingSwitch").Tag = forwarding;
            Element<Button>("ForwardingSwitch").Background = BrushFor(forwarding == "Enabled" ? "#62ADE2" : forwarding == "Disabled" ? "#C2D3E1" : "#E2EAF1");
            bool safe = UiPolicy.Safe(status);
            string safety = status == null || !status.Success ? "Not checked" : status.Safety == null || !status.Safety.Known ? "Inspection incomplete" : safe ? "No detected sharing" : "Protected topology";
            Text("SafetyValue", safety);
            string protection = Localization.T(safe ? "Automated checks found no sharing or routing dependency. Your manual topology confirmation is still required." : status != null && status.Safety != null && status.Safety.Known ? "A network change is blocked while sharing is detected or the inspection is incomplete. Do not disable services to bypass this." : "Some protection checks could not be completed. Forwarding can still be read; changes remain blocked.");
            if (status != null && status.Safety != null && status.Safety.Risks != null && status.Safety.Risks.Length > 0)
                protection += "\n" + Localization.T("Protection findings:") + "\n" + string.Join("\n", status.Safety.Risks.Select(Localization.T).ToArray());
            Text("SafetyExplanation", protection);
            string snapshot = ready && a.Snapshot != null ? a.Snapshot.State : "Unknown";
            Text("SnapshotValue", snapshot == "Valid" ? "Recovery available" : snapshot == "Absent" ? "No saved change" : snapshot == "Invalid" ? "Needs local review" : ready && a.Snapshot != null && a.Snapshot.Reason == "AdministratorRequired" ? "Administrator access needed" : "Unknown");
            Text("SnapshotExplanation", ready && a.Snapshot != null ? a.Snapshot.Message : "Snapshot status is unavailable. Administrator access may be needed to inspect protected recovery records.");
            bool fix = !busy && !manualReview && UiPolicy.CanFix(status, a);
            bool restore = !busy && !manualReview && UiPolicy.CanRestore(status, a);
            bool cleanup = UiPolicy.IsCleanup(a);
            Element<Button>("FixButton").IsEnabled = fix;
            Element<Button>("RestoreButton").IsEnabled = restore;
            Element<Button>("RestoreButton").Content = Localization.T(cleanup ? "Clear restored snapshot" : "Restore original setting");
            Element<Button>("ForwardingSwitch").IsEnabled = forwarding == "Enabled" ? fix : forwarding == "Disabled" && restore;
            if (manualReview) { Text("ActionTitle", "Recovery needs local review."); Text("ActionExplanation", "A rollback could not be verified. Keep the snapshot, stop repeating changes, and have a local administrator review the state. This session blocks further writes."); }
            else if (!ready) { Text("ActionTitle", "Start with a read-only check."); Text("ActionExplanation", "Refresh status to inspect a physical adapter. The app does not run or configure Clash."); }
            else if (status.IsAdministrator == false) { Text("ActionTitle", "Viewing is read-only."); Text("ActionExplanation", "To inspect protected recovery records or make a confirmed change, close the app, right-click this EXE and choose Run as administrator. It never elevates itself."); }
            else if (cleanup) { Text("ActionTitle", "The saved original is already active."); Text("ActionExplanation", "You can confirm cleanup of the valid recovery snapshot without changing forwarding. Only RESTORE confirmation is required for this cleanup."); }
            else if (forwarding == "Disabled" && snapshot == "Absent") { Text("ActionTitle", "Already off. Leave it as it is."); Text("ActionExplanation", "There is no original value saved by this tool, so it will not guess a restore setting or arbitrarily enable forwarding."); }
            else if (snapshot == "Invalid" || snapshot == "Unknown") { Text("ActionTitle", "Recovery state must be known."); Text("ActionExplanation", "An unreadable, damaged, expired or mismatched record needs local review. Confirmation cannot bypass snapshot validation."); }
            else if (!safe) { Text("ActionTitle", "The protection checks block a change."); Text("ActionExplanation", "Review the inspection notes. ICS, Mobile Hotspot, NAT, bridges and subnet routing can depend on forwarding. Unknown is not a safe result."); }
            else if (fix) { Text("ActionTitle", "A candidate workaround is available."); Text("ActionExplanation", "If your TUN failure fits this case, turn TUN off in Clash and review the confirmation. The original Enabled value will be saved before forwarding is disabled."); }
            else if (restore) { Text("ActionTitle", "You have a way back."); Text("ActionExplanation", "Restore the recorded original value for this same adapter. Review the topology and confirmation first; access can change during restoration."); }
            else { Text("ActionTitle", "This adapter is not ready for a change."); Text("ActionExplanation", "Fix requires an active physical adapter with a known IPv4 default route. Restore requires a valid record for this machine and adapter."); }
            var details = new StringBuilder();
            if (ready)
            {
                details.AppendLine(Localization.F("Adapter: {0}", a.InterfaceAlias)).AppendLine(Localization.F("GUID: {0}", a.InterfaceGuid)).AppendLine(Localization.F("Current index: {0}", a.InterfaceIndex)).AppendLine(Localization.F("Link status: {0}", Localization.T(a.Status))).AppendLine(Localization.F("IPv4 default route: {0}", Localization.T(!a.DefaultRouteKnown ? "Unknown" : a.HasDefaultRoute ? "Present" : "Absent")));
                if (!string.IsNullOrEmpty(a.ForwardingReadError)) details.AppendLine(Localization.F("Forwarding read failed: {0}", a.ForwardingReadError));
                if (!string.IsNullOrEmpty(a.DefaultRouteReadError)) details.AppendLine(Localization.F("Default-route read failed: {0}", a.DefaultRouteReadError));
            }
            if (status != null && status.Safety != null) foreach (string risk in status.Safety.Risks ?? new string[0]) details.AppendLine(Localization.F("Inspection: {0}", Localization.T(risk)));
            if (status != null) foreach (string message in status.Messages ?? new string[0]) details.AppendLine(message);
            if (status != null && !status.Success) details.AppendLine(status.Message);
            Text("DetailText", details.Length == 0 ? "No current inspection is available." : details.ToString());
            if (status != null)
            {
                DateTime refreshedUtc;
                Text("LastChecked", DateTime.TryParse(status.CheckedAtUtc, out refreshedUtc) ? Localization.F("Checked {0}", refreshedUtc.ToLocalTime().ToString("HH:mm:ss")) : "Time unavailable");
            }
        }
        private async Task Act(string mode)
        {
            if (busy || manualReview) return;
            AdapterStatus selected = Selected;
            if (!(mode == "Fix" ? UiPolicy.CanFix(status, selected) : UiPolicy.CanRestore(status, selected)))
            { Result("The current inspection does not permit this action. Refresh and review the state.", true); return; }
            bool cleanup = mode == "Restore" && UiPolicy.IsCleanup(selected);
            var request = new AdapterStatus { InterfaceGuid = selected.InterfaceGuid, InterfaceAlias = selected.InterfaceAlias, Forwarding = selected.Forwarding };
            bool confirmed = ConfirmDialog.Show(window, mode, cleanup, selected, demo);
            if (!confirmed) { Note(Localization.F("Cancelled {0}. No network write requested.", mode)); return; }
            writing = true; SetBusy(true, cleanup ? "Verifying the saved original and cleaning the snapshot" : "Operation in progress · Please keep this app open until verification finishes");
            ActionResult action = null;
            try
            {
                // Capture the request identity; disabling the picker prevents UI substitution.
                // Demo uses the fixture object; production uses the immutable captured values.
                AdapterStatus target = demo ? selected : request;
                action = await Task.Run(() => engine.Execute(mode, target, !cleanup, true));
                manualReview = action.RollbackFailed;
                Result(action.Message, !action.Success);
                foreach (string message in action.Messages ?? new string[0]) Note(message);
            }
            catch (Exception error)
            {
                manualReview = error.Message.IndexOf("ROLLBACK FAILED", StringComparison.OrdinalIgnoreCase) >= 0;
                Result(Localization.F("The operation did not report verified success: {0} Keep any recovery snapshot and inspect the current state.", error.Message), true);
            }
            finally
            {
                // Never stop/dispose an executing write pipeline or force-exit the process.
                // Execute returns only after the core's verification/compensation/finally.
                writing = false; busy = false;
            }
            await Refresh();
            if (manualReview) Text("FooterStatus", "ROLLBACK FAILED · Snapshot retained · Local review required");
            else Text("FooterStatus", action != null && action.Success ? "Operation verified · Test actual TUN traffic in Clash yourself" : "Operation not successful · Review session notes and current state");
        }
        private void Closing(object sender, CancelEventArgs e)
        {
            if (writing)
            {
                e.Cancel = true;
                MessageBox.Show(window, Localization.T("A network operation is still running. Wait for verification or recovery to finish before closing."), Localization.T("Operation in progress"), MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        private void ShowLicense()
        {
            var dialog = new Window { Owner = window, Title = Localization.T("License & notices"), Width = 660, Height = 600, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brushes.White, FontFamily = new FontFamily("Segoe UI") };
            dialog.Content = new TextBox { Text = EngineClient.Resource("TunAssist.License") + "\n\n" + EngineClient.Resource("TunAssist.Notice"), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0), Padding = new Thickness(24), FontSize = 13 };
            dialog.ShowDialog();
        }
    }
    internal static class ConfirmDialog
    {
        public static bool Show(Window owner, string mode, bool cleanup, AdapterStatus adapter, bool demo)
        {
            return Create(owner, mode, cleanup, adapter, demo).ShowDialog() == true;
        }
        internal static Window Create(Window owner, string mode, bool cleanup, AdapterStatus adapter, bool demo)
        {
            var dialog = new Window { Owner = owner, Title = cleanup ? "Review snapshot cleanup" : "Review forwarding change", Width = Math.Min(580, Math.Max(360, SystemParameters.WorkArea.Width - 48)), MaxHeight = Math.Min(760, Math.Max(360, SystemParameters.WorkArea.Height - 48)), SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Brushes.White, FontFamily = new FontFamily("Segoe UI"), FontSize = 14 };
            if (owner != null) dialog.Resources.MergedDictionaries.Add(owner.Resources);
            var body = new StackPanel { Margin = new Thickness(28) };
            body.Children.Add(new TextBlock { Text = cleanup ? "Clear a restored recovery record" : mode == "Fix" ? "Disable IPv4 packet forwarding?" : "Restore the saved original setting?", FontSize = 24, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)new BrushConverter().ConvertFromString("#213449") });
            body.Children.Add(new TextBlock { Text = adapter.InterfaceAlias + "  ·  " + adapter.InterfaceGuid, Margin = new Thickness(0, 14, 0, 16), FontSize = 12, TextWrapping = TextWrapping.Wrap });
            string explanation = cleanup ? "Forwarding already matches the saved Enabled value. This confirms snapshot cleanup only, after identity and state are rechecked. No network setting is written." : "This affects one adapter's IPv4 packet forwarding. It does not disable IPv4 or switch Clash TUN. Hotspot clients or other subnets can lose access if they depend on forwarding. The setting and adapter identity will be checked again before any write.";
            explanation = Localization.T(explanation);
            if (demo) explanation = Localization.T("DEMO: this dialog changes sample data only. No Windows setting or recovery file is touched.") + "\n\n" + explanation;
            body.Children.Add(new TextBlock { Text = explanation, LineHeight = 22, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 18) });
            var tunOff = new CheckBox { Content = "I have turned TUN off in Clash.", Margin = new Thickness(0, 0, 0, 12) };
            var noSharing = new CheckBox { Content = new TextBlock { Text = "This host does not provide ICS, a mobile hotspot, bridging or subnet forwarding, including third-party routing.", TextWrapping = TextWrapping.Wrap, MaxWidth = 475 }, Margin = new Thickness(0, 0, 0, 16) };
            var topology = new TextBox { Padding = new Thickness(10, 8, 10, 8), FontSize = 16, Margin = new Thickness(0, 6, 0, 16) };
            if (!cleanup)
            {
                body.Children.Add(tunOff); body.Children.Add(noSharing);
                body.Children.Add(new TextBlock { Text = "Type NO-SHARING to confirm the topology review.", FontSize = 12 }); body.Children.Add(topology);
            }
            body.Children.Add(new TextBlock { Text = Localization.F("Type {0} to confirm this action.", mode.ToUpperInvariant()), FontSize = 12 });
            var action = new TextBox { Padding = new Thickness(10, 8, 10, 8), FontSize = 16, Margin = new Thickness(0, 6, 0, 19) }; body.Children.Add(action);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            var cancel = new Button { Content = "Cancel", Padding = new Thickness(20, 10, 20, 10), Margin = new Thickness(0, 0, 10, 0), IsCancel = true };
            var confirm = new Button { Content = demo ? Localization.T("Confirm simulation") : cleanup ? Localization.T("Confirm cleanup") : Localization.F("Confirm {0}", mode.ToUpperInvariant()), Padding = new Thickness(20, 10, 20, 10), IsEnabled = false, Background = (Brush)new BrushConverter().ConvertFromString("#267CC2"), Foreground = Brushes.White };
            NameScope.SetNameScope(dialog, new NameScope());
            dialog.RegisterName("TunOffCheck", tunOff); dialog.RegisterName("NoSharingCheck", noSharing);
            dialog.RegisterName("TopologyWord", topology); dialog.RegisterName("ActionWord", action);
            dialog.RegisterName("ConfirmAction", confirm); dialog.RegisterName("CancelAction", cancel);
            Action update = delegate { confirm.IsEnabled = UiPolicy.Confirmed(mode, cleanup, tunOff.IsChecked == true, noSharing.IsChecked == true, topology.Text, action.Text); };
            tunOff.Checked += delegate { update(); }; tunOff.Unchecked += delegate { update(); }; noSharing.Checked += delegate { update(); }; noSharing.Unchecked += delegate { update(); };
            topology.TextChanged += delegate { update(); }; action.TextChanged += delegate { update(); };
            confirm.Click += delegate { if (confirm.IsEnabled) dialog.DialogResult = true; };
            cancel.Click += delegate { dialog.DialogResult = false; };
            buttons.Children.Add(cancel); buttons.Children.Add(confirm); body.Children.Add(buttons);
            dialog.Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            Localization.ApplyTree(dialog);
            return dialog;
        }
    }
    internal static class SelfTests
    {
        public static string Run()
        {
            Localization.Select("en");
            int count = 0;
            Action<bool, string> check = delegate(bool condition, string label) { if (!condition) throw new InvalidOperationException("Self-test failed: " + label); count++; };
            StatusResult s = EngineClient.DemoStatus(); AdapterStatus a = s.Adapters[0];
            check(UiPolicy.CanFix(s, a), "eligible Enabled/Absent can Fix");
            check(!UiPolicy.CanRestore(s, a), "absent snapshot cannot Restore");
            s.Safety.Known = false; check(!UiPolicy.CanFix(s, a), "unknown topology blocks Fix"); s.Safety.Known = true;
            s.Safety.Risks = new[] { "ICS" }; check(!UiPolicy.CanFix(s, a), "protected topology blocks Fix"); s.Safety.Risks = new string[0];
            s.IsAdministrator = false; check(!UiPolicy.CanFix(s, a), "ordinary user cannot Fix"); s.IsAdministrator = true;
            a.DefaultRouteKnown = false; check(!UiPolicy.CanFix(s, a), "unknown route blocks Fix"); a.DefaultRouteKnown = true;
            a.HasDefaultRoute = false; check(!UiPolicy.CanFix(s, a), "no route blocks Fix"); a.HasDefaultRoute = true;
            a.PhysicalEligible = false; check(!UiPolicy.CanFix(s, a), "virtual selection blocked"); a.PhysicalEligible = true;
            a.Forwarding = "Unknown"; check(!UiPolicy.CanFix(s, a) && !UiPolicy.CanRestore(s, a), "unknown forwarding blocks writes"); a.Forwarding = "Enabled";
            a.Snapshot.State = "Unknown"; a.Snapshot.Known = false; check(!UiPolicy.CanFix(s, a), "unknown storage blocks Fix");
            a.Snapshot = new SnapshotStatus { State = "Valid", Known = true, Present = true, Valid = true };
            check(!UiPolicy.CanFix(s, a), "existing snapshot cannot be overwritten");
            s.Safety.Known = false; check(UiPolicy.CanRestore(s, a) && UiPolicy.IsCleanup(a), "already-original cleanup needs no topology");
            a.Forwarding = "Disabled"; check(!UiPolicy.CanRestore(s, a), "unknown topology blocks restoring network");
            s.Safety.Known = true; check(UiPolicy.CanRestore(s, a), "valid snapshot permits Restore");
            a.Status = "Disconnected"; a.HasDefaultRoute = false; check(UiPolicy.CanRestore(s, a), "offline/no-route recovery allowed");
            a.Snapshot.Valid = false; check(!UiPolicy.CanRestore(s, a), "presence is not snapshot validity");
            check(!UiPolicy.Confirmed("Fix", false, true, true, "NO-SHARING", "fix"), "confirmation case exact");
            check(!UiPolicy.Confirmed("Fix", false, true, false, "NO-SHARING", "FIX"), "manual topology check required");
            check(!UiPolicy.Confirmed("Fix", false, false, true, "NO-SHARING", "FIX"), "TUN-off acknowledgement required");
            check(UiPolicy.Confirmed("Restore", true, false, false, "", "RESTORE"), "cleanup confirmation only");
            check(!UiPolicy.Confirmed("Fix", true, false, false, "", "FIX"), "cleanup exception only Restore");
            var fake = new EngineClient(true); StatusResult fs = fake.ReadStatus();
            check(fake.Execute("Fix", fs.Adapters[0], true, true).Success && fs.Adapters[0].Forwarding == "Disabled", "demo Fix simulates only");
            check(fake.Execute("Restore", fs.Adapters[0], true, true).Success && fs.Adapters[0].Forwarding == "Enabled", "demo Restore simulates only");
            bool refused = false; try { fake.Execute("Fix", fs.Adapters[0], true, false); } catch { refused = true; }
            check(refused, "engine action confirmation required");
            check(EngineClient.Resource("TunAssist.Window").Contains("NOT TUN ON/OFF"), "switch scope is visible");
            check(EngineClient.Resource("TunAssist.Core").Contains("ROLLBACK FAILED"), "embedded recovery core present");
            check(EngineClient.Resource("TunAssist.Bridge").Contains("ExpectedForwarding"), "bridge state binding present");
            // Construct embedded WPF controls in demo mode, without showing a window
            // or constructing a Windows backend. Exercise the actual event bindings.
            Window view = (Window)XamlReader.Parse(EngineClient.Resource("TunAssist.Window"));
            var controller = new MainController(view, true, false);
            var picker = (ComboBox)view.FindName("AdapterPicker");
            var switchControl = (Button)view.FindName("ForwardingSwitch");
            check(switchControl.IsEnabled && (string)switchControl.Tag == "Enabled", "demo switch reflects Enabled candidate");
            picker.SelectedIndex = 1;
            check(!switchControl.IsEnabled && (string)switchControl.Tag == "Disabled", "Disabled without record cannot enable switch");
            AdapterStatus sample = (AdapterStatus)picker.SelectedItem;
            sample.Snapshot = new SnapshotStatus { State = "Valid", Known = true, Present = true, Valid = true, Message = "Sample" };
            picker.SelectedIndex = 0; picker.SelectedIndex = 1;
            check(switchControl.IsEnabled && ((Button)view.FindName("RestoreButton")).IsEnabled, "offline valid-record Restore reaches UI");
            sample.Forwarding = "Unknown"; picker.SelectedIndex = 0; picker.SelectedIndex = 1;
            check(!switchControl.IsEnabled && !((Button)view.FindName("RestoreButton")).IsEnabled, "unknown state disables actual controls");
            foreach (string key in new[] { "Guide", "Activity", "About", "Language", "Dashboard" })
            {
                string nav = key == "Dashboard" ? "DashboardNav" : key == "Guide" ? "GuideNav" : key + "Nav";
                ((Button)view.FindName(nav)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                check(((StackPanel)view.FindName(key + "Page")).Visibility == Visibility.Visible, key + " navigation displays embedded page");
            }
            picker.SelectedIndex = 0;
            StatusResult failedRead = EngineClient.DemoStatus(); failedRead.Success = false; failedRead.Message = "Simulated CIM failure";
            typeof(MainController).GetMethod("ApplyStatus", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(controller, new object[] { failedRead });
            check(picker.Items.Count == 0 && !switchControl.IsEnabled && !((Button)view.FindName("FixButton")).IsEnabled && !((Button)view.FindName("RestoreButton")).IsEnabled && ((TextBlock)view.FindName("ForwardingValue")).Text == "Unknown", "failed scan clears cached adapter and all write controls");
            Window confirmation = ConfirmDialog.Create(null, "Fix", false, EngineClient.DemoStatus().Adapters[0], true);
            var confirm = (Button)confirmation.FindName("ConfirmAction");
            check(!confirm.IsEnabled && ((Button)confirmation.FindName("CancelAction")).IsCancel, "confirmation starts disabled and offers cancel");
            ((TextBox)confirmation.FindName("TopologyWord")).Text = "NO-SHARING";
            ((TextBox)confirmation.FindName("ActionWord")).Text = "FIX";
            check(!confirm.IsEnabled, "typed words alone do not confirm UI");
            ((CheckBox)confirmation.FindName("TunOffCheck")).IsChecked = true;
            ((CheckBox)confirmation.FindName("NoSharingCheck")).IsChecked = true;
            check(confirm.IsEnabled, "complete confirmation enables UI action");
            ((TextBox)confirmation.FindName("ActionWord")).Text = "fix";
            check(!confirm.IsEnabled, "UI event binding revokes mismatched confirmation");
            Window cleanupView = ConfirmDialog.Create(null, "Restore", true, EngineClient.DemoStatus().Adapters[0], true);
            ((TextBox)cleanupView.FindName("ActionWord")).Text = "RESTORE";
            check(((Button)cleanupView.FindName("ConfirmAction")).IsEnabled, "cleanup UI requires only RESTORE");
            var languagePicker = (ListBox)view.FindName("LanguagePicker");
            var protectedSample = EngineClient.DemoStatus(); protectedSample.IsAdministrator = false;
            protectedSample.Safety.Known = false; protectedSample.Safety.Risks = new[] { "ICS inspection unavailable" };
            protectedSample.Adapters[0].Snapshot = new SnapshotStatus { State = "Unknown", Reason = "AdministratorRequired", Known = false, Message = "Run as administrator to inspect protected recovery snapshots." };
            typeof(MainController).GetMethod("ApplyStatus", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(controller, new object[] { protectedSample });
            foreach (LanguageChoice language in Localization.Languages)
            {
                languagePicker.SelectedItem = language;
                check(Localization.Code == language.Code, "language picker applies " + language.Code);
                check(((TextBlock)view.FindName("ForwardingValue")).Text == Localization.T("Enabled") && ((AdapterStatus)picker.SelectedItem).Forwarding == "Enabled", "translated display retains raw enum " + language.Code);
                check(!switchControl.IsEnabled && !((Button)view.FindName("FixButton")).IsEnabled && !((Button)view.FindName("RestoreButton")).IsEnabled, "language change never authorizes write " + language.Code);
                check(((TextBlock)view.FindName("SnapshotValue")).Text == Localization.T("Administrator access needed"), "permission unknown has specific label " + language.Code);
                check(((Button)view.FindName("GuideNav")).Content.ToString() == Localization.T("How it works"), "static navigation updates " + language.Code);
                Window localConfirmation = ConfirmDialog.Create(null, "Fix", false, protectedSample.Adapters[0], true);
                ((TextBox)localConfirmation.FindName("TopologyWord")).Text = "NO-SHARING";
                ((TextBox)localConfirmation.FindName("ActionWord")).Text = "FIX";
                ((CheckBox)localConfirmation.FindName("TunOffCheck")).IsChecked = true;
                ((CheckBox)localConfirmation.FindName("NoSharingCheck")).IsChecked = true;
                check(((Button)localConfirmation.FindName("ConfirmAction")).IsEnabled, "literal FIX/NO-SHARING works in " + language.Code);
                ((TextBox)localConfirmation.FindName("ActionWord")).Text = Localization.T("Enabled");
                check(!((Button)localConfirmation.FindName("ConfirmAction")).IsEnabled, "display word cannot confirm action in " + language.Code);
            }
            Localization.Select("en");
            GC.KeepAlive(controller);
            return "Desktop self-tests: " + count + " passed; real network calls: 0.\r\n";
        }
    }
}
