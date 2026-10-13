using System.IO;
using Microsoft.Win32;

namespace StowLab;

enum Backdrop { Acrylic, Mica, Solid }

/// The Lab's options, set from its main window.
static class Lab
{
    public static bool ShowOnEdge = true;
    public static bool ShowOnShake = true;
    public static bool ShowOnGuess = false;
    public static bool RemoveAfterDrag = true;
    public static bool ShowStrips = false;
    public static DragOutMode DragOutMode = DragOutMode.PreferCopy;
    public static Backdrop Backdrop = Backdrop.Acrylic;

    public static readonly string DataFolder =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StowLab");

    /// Where virtual files dropped on the shelf are saved, one folder per drop.
    public static string PromisedFolder => Path.Combine(DataFolder, "Promised");
}

/// Writes to the Lab window and to %LOCALAPPDATA%\StowLab\lab.log. Safe from any thread.
static class Log
{
    public static event Action<string>? Line;
    public static string FilePath { get; } = Path.Combine(Lab.DataFolder, "lab.log");
    static readonly object gate = new();

    public static void Write(string message)
    {
        string line = $"{DateTime.Now:HH:mm:ss.fff}  {message}";
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(Lab.DataFolder);
                File.AppendAllText(FilePath, line + Environment.NewLine);
            }
            catch { /* the window still shows it */ }
        }
        Line?.Invoke(line);
    }
}

static class Theme
{
    /// Whether apps are set to dark mode (Settings → Personalization → Colors).
    public static bool IsDark
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
                return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
            }
            catch
            {
                return false;
            }
        }
    }
}
