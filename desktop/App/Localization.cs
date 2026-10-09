using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;

namespace TunAssist
{
    public sealed class LanguageChoice
    {
        public string Code { get; set; }
        public string NativeName { get; set; }
    }
    public static class Localization
    {
        public static readonly LanguageChoice[] Languages = new[] {
            new LanguageChoice { Code = "en", NativeName = "English" },
            new LanguageChoice { Code = "ja", NativeName = "日本語" },
            new LanguageChoice { Code = "zh", NativeName = "中文（简体）" },
            new LanguageChoice { Code = "ms", NativeName = "Bahasa Melayu" },
            new LanguageChoice { Code = "it", NativeName = "Italiano" },
            new LanguageChoice { Code = "de", NativeName = "Deutsch" },
            new LanguageChoice { Code = "ru", NativeName = "Русский" }
        };
        private static readonly Dictionary<string, Dictionary<string, string>> cache = new Dictionary<string, Dictionary<string, string>>();
        private static Dictionary<string, string> current = new Dictionary<string, string>();
        public static string Code { get; private set; }
        private static readonly DependencyProperty TextSource = DependencyProperty.RegisterAttached("TextSource", typeof(string), typeof(Localization));
        private static readonly DependencyProperty ContentSource = DependencyProperty.RegisterAttached("ContentSource", typeof(string), typeof(Localization));
        private static readonly DependencyProperty HeaderSource = DependencyProperty.RegisterAttached("HeaderSource", typeof(string), typeof(Localization));
        private static readonly DependencyProperty ToolTipSource = DependencyProperty.RegisterAttached("ToolTipSource", typeof(string), typeof(Localization));
        private static readonly DependencyProperty TitleSource = DependencyProperty.RegisterAttached("TitleSource", typeof(string), typeof(Localization));
        public static bool Supported(string code) { return Languages.Any(x => x.Code == code); }
        public static void Select(string code)
        {
            if (!Supported(code)) throw new InvalidOperationException("Unsupported display language.");
            Dictionary<string, string> catalog;
            if (!cache.TryGetValue(code, out catalog))
            {
                catalog = new JavaScriptSerializer { MaxJsonLength = 1048576 }.Deserialize<Dictionary<string, string>>(EngineClient.Resource("TunAssist.Locale." + code));
                if (catalog == null || catalog.Count == 0) throw new InvalidOperationException("Language resource is empty.");
                cache.Add(code, catalog);
            }
            current = catalog; Code = code;
        }
        public static string T(string source)
        {
            if (source == null) return "";
            string result;
            return current.TryGetValue(source, out result) && !string.IsNullOrEmpty(result) ? result : source;
        }
        public static string F(string source, params object[] args) { return string.Format(CultureInfo.CurrentCulture, T(source), args); }
        public static void SetText(TextBlock block, string source) { block.SetValue(TextSource, source); block.Text = T(source); }
        private static void ApplyString(DependencyObject obj, DependencyProperty target, DependencyProperty source)
        {
            string original = obj.GetValue(source) as string;
            if (original == null)
            {
                original = obj.GetValue(target) as string;
                if (string.IsNullOrEmpty(original)) return;
                obj.SetValue(source, original);
            }
            obj.SetValue(target, T(original));
        }
        public static void ApplyTree(DependencyObject root)
        {
            var text = root as TextBlock;
            if (text != null) ApplyString(root, TextBlock.TextProperty, TextSource);
            var content = root as ContentControl;
            if (content != null) ApplyString(root, ContentControl.ContentProperty, ContentSource);
            var header = root as HeaderedContentControl;
            if (header != null) ApplyString(root, HeaderedContentControl.HeaderProperty, HeaderSource);
            var element = root as FrameworkElement;
            if (element != null) ApplyString(root, FrameworkElement.ToolTipProperty, ToolTipSource);
            var window = root as Window;
            if (window != null) ApplyString(root, Window.TitleProperty, TitleSource);
            foreach (object child in LogicalTreeHelper.GetChildren(root))
            {
                var node = child as DependencyObject;
                if (node != null) ApplyTree(node);
            }
        }
    }
    internal static class UserPreferences
    {
        // Only an allow-listed UI language is stored. It is never executed or
        // passed to the network engine. Demo/self-test/render never access this path.
        private static string PathName { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TunAssist", "language.txt"); } }
        public static string Load()
        {
            try {
                if (!File.Exists(PathName) || new FileInfo(PathName).Length > 16) return "en";
                string code = File.ReadAllText(PathName, Encoding.UTF8).Trim();
                return Localization.Supported(code) ? code : "en";
            } catch { return "en"; }
        }
        public static void Save(string code)
        {
            if (!Localization.Supported(code)) throw new InvalidOperationException("Unsupported display language.");
            if (EngineClient.IsAdministrator()) return;
            string path = PathName; Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new StreamWriter(file, new UTF8Encoding(false))) { writer.Write(code); writer.Flush(); file.Flush(true); }
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
    }
}
