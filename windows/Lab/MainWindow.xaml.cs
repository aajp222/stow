using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using static StowLab.Native;

namespace StowLab;

/// <summary>
/// The Lab's control panel and log. It wires the pieces together: the mouse hook
/// (DragWatcher), the edge strips, and the shelf.
/// </summary>
public partial class MainWindow : Window
{
    readonly ShelfWindow shelf;
    readonly List<EdgeStrip> strips = new();
    DragWatcher? watcher;

    public MainWindow()
    {
        InitializeComponent();
        // Made here, not as a field initializer: WPF makes the first window created its
        // "main window" (the one whose closing quits the app), and field initializers
        // run before this window exists.
        shelf = new ShelfWindow();
        Log.Line += line => Dispatcher.InvokeAsync(() =>
        {
            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
        });

        // Hooked up here rather than in the XAML, so they don't fire while the window is
        // still being built.
        foreach (var box in new[] { EdgeBox, ShakeBox, GuessBox, RemoveBox, StripsBox })
        {
            box.Checked += OptionChanged;
            box.Unchecked += OptionChanged;
        }
        PreferCopyRadio.Checked += OptionChanged;
        CopyOnlyRadio.Checked += OptionChanged;
        BackdropBox.SelectionChanged += OptionChanged;
        ReadOptions();

        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    void OnLoaded(object sender, RoutedEventArgs e)
    {
        LogEnvironment();
        BuildStrips();

        watcher = new DragWatcher(Dispatcher);
        watcher.GestureStarted += _ =>
        {
            foreach (var strip in strips) strip.Armed = true;
        };
        watcher.ButtonReleased += inStow =>
        {
            foreach (var strip in strips) strip.Armed = false;
            if (!inStow) shelf.HideIfEmptySoon();
        };
        watcher.Shaken += pointer =>
        {
            if (Lab.ShowOnShake) shelf.ShowNear(pointer, "shake");
        };
        watcher.LooksLikeDragAndDrop += pointer =>
        {
            if (Lab.ShowOnGuess) shelf.ShowNear(pointer, "guess");
        };

        // Displays plugged in, unplugged or rescaled, and dark/light mode switches,
        // are announced to every top-level window.
        HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(WindowMessage);
    }

    IntPtr WindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WM_DISPLAYCHANGE)
        {
            Log.Write("Displays changed: rebuilding the edge strips.");
            Dispatcher.InvokeAsync(BuildStrips);
        }
        else if (message == WM_SETTINGCHANGE && lParam != 0 && Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet")
        {
            shelf.ApplyLook();
        }
        return IntPtr.Zero;
    }

    void OnClosed(object? sender, EventArgs e)
    {
        watcher?.Dispose();
        foreach (var strip in strips) strip.Close();
        shelf.Close();
    }

    /// One strip on the left and one on the right edge of every display.
    void BuildStrips()
    {
        foreach (var strip in strips) strip.Close();
        strips.Clear();
        foreach (var monitor in Monitors())
        {
            var bounds = MonitorInfo(monitor).rcMonitor;
            foreach (bool left in new[] { true, false })
            {
                var strip = new EdgeStrip(bounds, left);
                strip.DragTouched += (pointer, accepted) =>
                {
                    if (Lab.ShowOnEdge && accepted) shelf.ShowNear(pointer, "edge");
                };
                strip.Show();
                strip.Place();
                strip.Place();
                strips.Add(strip);
            }
        }
    }

    void LogEnvironment()
    {
        var version = Environment.OSVersion.Version;
        Log.Write($"Stow Lab {Assembly.GetExecutingAssembly().GetName().Version} on Windows {version} ({RuntimeInformation.OSArchitecture}; the Lab runs as {RuntimeInformation.ProcessArchitecture}), .NET {Environment.Version}.");
        if (version.Build < 22000) Log.Write("  This isn't Windows 11. Stow for Windows will need Windows 11.");
        Log.Write($"  Dark mode: {(Theme.IsDark ? "on" : "off")}. Buttons swapped: {(GetSystemMetrics(SM_SWAPBUTTON) != 0 ? "yes" : "no")}.");
        foreach (var monitor in Monitors())
        {
            var info = MonitorInfo(monitor);
            Log.Write($"  Display: {info.rcMonitor}, usable area {info.rcWork}, scaling {Dpi(monitor) * 100 / 96}%{((info.dwFlags & 1) != 0 ? " (main)" : "")}.");
        }
        Log.Write($"  Log file: {Log.FilePath}");
    }

    void OptionChanged(object sender, RoutedEventArgs e)
    {
        var oldBackdrop = Lab.Backdrop;
        bool oldStrips = Lab.ShowStrips;
        ReadOptions();
        if (Lab.Backdrop != oldBackdrop) shelf.ApplyLook();
        if (Lab.ShowStrips != oldStrips) foreach (var strip in strips) strip.UpdateTint();
    }

    void ReadOptions()
    {
        Lab.ShowOnEdge = EdgeBox.IsChecked == true;
        Lab.ShowOnShake = ShakeBox.IsChecked == true;
        Lab.ShowOnGuess = GuessBox.IsChecked == true;
        Lab.RemoveAfterDrag = RemoveBox.IsChecked == true;
        Lab.ShowStrips = StripsBox.IsChecked == true;
        Lab.DragOutMode = CopyOnlyRadio.IsChecked == true ? DragOutMode.CopyOnlyUnlessShift : DragOutMode.PreferCopy;
        Lab.Backdrop = (Backdrop)Math.Max(BackdropBox.SelectedIndex, 0);
    }

    void ShowShelf_Click(object sender, RoutedEventArgs e)
    {
        GetCursorPos(out var pointer);
        shelf.ShowNear(pointer, "button");
    }

    void HideShelf_Click(object sender, RoutedEventArgs e) => shelf.Hide();

    void ClearShelf_Click(object sender, RoutedEventArgs e) => shelf.Items.Clear();

    void OpenPromised_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(Lab.PromisedFolder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Lab.PromisedFolder}\"") { UseShellExecute = true });
    }

    void CopyLog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(LogBox.Text);
            Log.Write("Log copied to the clipboard.");
        }
        catch (Exception ex)
        {
            // Another app can be holding the clipboard open for a moment.
            MessageBox.Show(this, $"Couldn't copy the log ({ex.Message}). It's also saved at {Log.FilePath}.", "Stow Lab");
        }
    }

    void ClearLog_Click(object sender, RoutedEventArgs e) => LogBox.Clear();
}
