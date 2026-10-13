using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using static StowLab.Native;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace StowLab;

/// <summary>
/// The Lab's shelf: a floating window that never takes focus from the app you're in,
/// takes drops from other apps and lets you drag its items back out.
/// </summary>
public partial class ShelfWindow : Window
{
    /// The shelf's size in DIPs (1/96 inch). Kept here rather than read back from
    /// Width/Height, which WPF rewrites while it rescales the window between displays.
    const double ShelfWidth = 150, ShelfHeight = 420, EdgeGap = 8;

    public ObservableCollection<ShelfItem> Items { get; } = new();

    IntPtr hwnd;
    OleDropTarget? dropTarget;
    ComDataObject? dragOverShelf;
    bool dragAccepted;
    /// A drop is being read. Asking the source app for a virtual file's bytes is a
    /// call into another process, and while COM waits for the answer it keeps handling
    /// messages, so timers (like the hide-if-empty one) can fire mid-drop.
    bool receivingDrop;
    IntPtr previousForeground;
    DispatcherTimer? hideTimer;

    // Clicking and dragging items.
    Point? pressPoint;
    ShelfItem? pressItem;
    bool selectOnlyOnRelease;
    ShelfItem? anchor;

    public ShelfWindow()
    {
        InitializeComponent();
        List.ItemsSource = Items;
        Items.CollectionChanged += (_, _) => EmptyText.Visibility = Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SourceInitialized += OnSourceInitialized;
        // Clicking another app after typing in the focus box: back to never taking focus.
        Deactivated += (_, _) => { if (hwnd != 0) SetExStyle(hwnd, WS_EX_NOACTIVATE, 0); };
        // Create the window now (without showing it) so it can take drops from the start.
        new WindowInteropHelper(this).EnsureHandle();
    }

    void OnSourceInitialized(object? sender, EventArgs e)
    {
        hwnd = new WindowInteropHelper(this).Handle;
        // WS_EX_NOACTIVATE: clicking the shelf doesn't take the focus from the app you're
        // in (like the Mac's .nonactivatingPanel). WS_EX_TOOLWINDOW: no taskbar button,
        // not in Alt+Tab, and (one of the Phase 0 checks) on every virtual desktop.
        SetExStyle(hwnd, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, 0);
        ApplyLook();
        dropTarget = OleDropTarget.Register(hwnd, "shelf");
        dropTarget.Enter = OnDragEnter;
        dropTarget.Over = OnDragOver;
        dropTarget.Leave = OnDragLeave;
        dropTarget.Dropped = OnDrop;
    }

    // ------------------------------------------------------------------ Look

    /// Dark or light to match Windows, rounded corners, and the background the Lab's
    /// main window asks for.
    public void ApplyLook()
    {
        if (hwnd == 0) return;
        bool dark = Theme.IsDark;
        int darkMode = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkMode, sizeof(int));
        int corners = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corners, sizeof(int));
        Foreground = dark ? Brushes.White : Brushes.Black;

        var target = HwndSource.FromHwnd(hwnd)?.CompositionTarget;
        if (Lab.Backdrop == Backdrop.Solid)
        {
            var color = dark ? Color.FromRgb(0x20, 0x20, 0x20) : Color.FromRgb(0xF3, 0xF3, 0xF3);
            if (target is not null) target.BackgroundColor = color;
            Background = new SolidColorBrush(color);
            int none = DWMSBT_NONE;
            DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref none, sizeof(int));
        }
        else
        {
            // Let Windows' compositor (DWM) paint the background: stretch the window's
            // "frame" over all of it, and make WPF's background see-through so the
            // backdrop shows. Acrylic is the frosted glass Windows uses for menus; Mica
            // is the subtler tint of main windows.
            if (target is not null) target.BackgroundColor = Colors.Transparent;
            Background = Brushes.Transparent;
            var margins = new MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
            int backdrop = Lab.Backdrop == Backdrop.Acrylic ? DWMSBT_TRANSIENTWINDOW : DWMSBT_MAINWINDOW;
            int result = DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
            if (result != 0) Log.Write($"Windows refused the {Lab.Backdrop} background: error 0x{result:X8}");
        }
    }

    // ------------------------------------------------------------------ Showing and hiding

    /// Shows the shelf at the left or right edge (whichever is nearer) of the display
    /// the pointer is on, vertically centred, clear of the taskbar.
    internal void ShowNear(POINT pointer, string reason)
    {
        hideTimer?.Stop();
        IntPtr monitor = MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST);
        var info = MonitorInfo(monitor);
        var work = info.rcWork; // the display minus the taskbar
        double scale = Dpi(monitor) / 96.0;
        int width = (int)Math.Round(ShelfWidth * scale), height = (int)Math.Round(ShelfHeight * scale), gap = (int)Math.Round(EdgeGap * scale);
        bool left = pointer.X - work.Left < work.Right - pointer.X;
        int x = left ? work.Left + gap : work.Right - width - gap;
        int y = work.Top + (work.Height - height) / 2;

        bool wasVisible = IsVisible;
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
        if (!wasVisible) Show(); // ShowActivated="False": shown without taking focus
        // Again: moving onto a display with different scaling makes Windows rescale the
        // window after the move, and this puts the size back.
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
        if (!wasVisible)
            Log.Write($"Shelf shown ({reason}) at the {(left ? "left" : "right")} edge of a {info.rcMonitor.Width}×{info.rcMonitor.Height} display at {Math.Round(scale * 100)}%.");
    }

    /// When a drag ends: wait 0.3 s (the drop may still be arriving), then hide if empty.
    public void HideIfEmptySoon()
    {
        hideTimer?.Stop();
        hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        hideTimer.Tick += (_, _) =>
        {
            if (receivingDrop) return; // look again in 0.3 s, once the drop has landed
            hideTimer?.Stop();
            if (Items.Count == 0 && IsVisible)
            {
                Hide();
                Log.Write("Shelf hidden: the drag ended and it's empty.");
            }
        };
        hideTimer.Start();
    }

    void Hide_Click(object sender, RoutedEventArgs e) => Hide();

    // ------------------------------------------------------------------ Drops

    int OnDragEnter(ComDataObject data, POINT point, int keyState, int allowed)
    {
        if (DragOut.InProgress)
        {
            dragAccepted = false; // the shelf's own drag; reordering comes in Phase 5
            return DROPEFFECT_NONE;
        }
        dragOverShelf = data;
        dragAccepted = DataReader.Accepts(data);
        int effect = dragAccepted ? Choose(allowed) : DROPEFFECT_NONE;
        Log.Write($"Drag entered the shelf. Source allows: {DataReader.Effects(allowed)}. Formats: {DataReader.DescribeFormats(data)}");
        if (dragAccepted && effect == DROPEFFECT_NONE)
            Log.Write("  The source only allows moving. Refused, so it can't delete the original after the drop.");
        if (effect != DROPEFFECT_NONE)
            DataReader.TrySetDropDescription(data, DROPIMAGE_COPY, "Add to %1", "Stow Lab");
        return effect;
    }

    int OnDragOver(POINT point, int keyState, int allowed) =>
        dragAccepted && !DragOut.InProgress ? Choose(allowed) : DROPEFFECT_NONE;

    void OnDragLeave()
    {
        // Clear our label so the next window under the drag gets its own.
        if (dragOverShelf is not null) DataReader.TrySetDropDescription(dragOverShelf, DROPIMAGE_INVALID, "", "");
        dragOverShelf = null;
    }

    /// Copy if the source allows it. Never move: the shelf keeps a reference to the
    /// original, and a source told "moved" deletes its copy.
    static int Choose(int allowed) =>
        (allowed & DROPEFFECT_COPY) != 0 ? DROPEFFECT_COPY
        : (allowed & DROPEFFECT_LINK) != 0 ? DROPEFFECT_LINK
        : DROPEFFECT_NONE;

    int OnDrop(ComDataObject data, POINT point, int keyState, int allowed)
    {
        dragOverShelf = null;
        if (DragOut.InProgress || !dragAccepted) return DROPEFFECT_NONE;
        int effect = Choose(allowed);
        if (effect == DROPEFFECT_NONE) return DROPEFFECT_NONE;
        var clock = Stopwatch.StartNew();
        Log.Write("Dropped on the shelf:");
        receivingDrop = true;
        int added;
        try { added = AddFrom(data); }
        finally { receivingDrop = false; }
        Log.Write($"  Added {added} item(s) in {clock.ElapsedMilliseconds} ms.");
        return added > 0 ? effect : DROPEFFECT_NONE;
    }

    int AddFrom(ComDataObject data)
    {
        // Real files first: some sources (browsers, for one) offer both paths and
        // virtual files for the same thing.
        if (DataReader.Has(data, Formats.CF_HDROP, System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL))
        {
            var paths = DataReader.FilePaths(data);
            Log.Write($"  By path: {string.Join(", ", paths)}");
            foreach (var path in paths) Items.Add(ShelfItem.File(path, promised: false));
            return paths.Length;
        }
        if (DataReader.Has(data, Formats.FileGroupDescriptorW))
        {
            string folder = Path.Combine(Lab.PromisedFolder, Guid.NewGuid().ToString("N")[..8]);
            var saved = DataReader.SaveVirtualFiles(data, folder);
            foreach (var path in saved) Items.Add(ShelfItem.File(path, promised: true));
            return saved.Count;
        }
        string? url = DataReader.Text(data, Formats.UrlW, unicode: true) ?? DataReader.Text(data, Formats.Url, unicode: false);
        if (url is not null)
        {
            Log.Write($"  Link: {url}");
            Items.Add(new ShelfItem { Kind = ItemKind.Link, Name = url, Text = url });
            return 1;
        }
        if (DataReader.Text(data, Formats.CF_UNICODETEXT, unicode: true) is string text)
        {
            Log.Write($"  Text: {(text.Length > 80 ? text[..80] + "…" : text)}");
            string firstLine = text.Split('\n')[0].Trim();
            Items.Add(new ShelfItem { Kind = ItemKind.Text, Name = firstLine.Length > 0 ? firstLine : "Text", Text = text });
            return 1;
        }
        if (DataReader.Has(data, Formats.Png) || DataReader.Has(data, Formats.CF_DIBV5) || DataReader.Has(data, Formats.CF_DIB))
        {
            Log.Write("  Image data only, no file. (Phase 4 saves these as PNGs.)");
            return 0;
        }
        if (DataReader.Has(data, Formats.ShellIdList))
        {
            Log.Write("  Shell items with no file paths. Not handled in the Lab.");
            return 0;
        }
        Log.Write("  Nothing the Lab can read.");
        return 0;
    }

    // ------------------------------------------------------------------ Selecting and dragging out

    // The shelf does its own selecting. WPF's ListBox decides Ctrl- and Shift-clicks
    // from the keys it saw pressed in its own window, and the shelf never has the
    // keyboard, so it asks the hardware instead (IsKeyDown). And a plain click on an
    // item that's already selected waits for the button to come up before selecting
    // only that item, so that dragging several selected items works.

    void List_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var item = ItemUnder(e.OriginalSource);
        pressPoint = e.GetPosition(List);
        pressItem = item;
        selectOnlyOnRelease = false;
        if (item is null)
        {
            List.SelectedItems.Clear();
            return;
        }
        if (IsKeyDown(VK_CONTROL))
        {
            if (List.SelectedItems.Contains(item)) List.SelectedItems.Remove(item);
            else List.SelectedItems.Add(item);
            anchor = item;
        }
        else if (IsKeyDown(VK_SHIFT) && anchor is not null && Items.Contains(anchor))
        {
            int from = Items.IndexOf(anchor), to = Items.IndexOf(item);
            List.SelectedItems.Clear();
            for (int i = Math.Min(from, to); i <= Math.Max(from, to); i++) List.SelectedItems.Add(Items[i]);
        }
        else if (List.SelectedItems.Contains(item))
        {
            selectOnlyOnRelease = true;
        }
        else
        {
            List.SelectedItems.Clear();
            List.SelectedItems.Add(item);
            anchor = item;
        }
    }

    void List_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (selectOnlyOnRelease && pressItem is not null)
        {
            List.SelectedItems.Clear();
            List.SelectedItems.Add(pressItem);
            anchor = pressItem;
        }
        pressPoint = null;
        selectOnlyOnRelease = false;
    }

    void List_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (pressPoint is not Point start || e.LeftButton != MouseButtonState.Pressed) return;
        var position = e.GetPosition(List);
        if (Math.Abs(position.X - start.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(position.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        pressPoint = null;
        selectOnlyOnRelease = false;
        var items = List.SelectedItems.Cast<ShelfItem>().Where(i => i.Kind == ItemKind.File && i.Path is not null).ToList();
        if (items.Count == 0)
        {
            Log.Write("Only files can be dragged out of the Lab's shelf (links and text come in Phase 4).");
            return;
        }
        Mouse.Capture(null);
        DragItemsOut(items);
    }

    void DragItemsOut(List<ShelfItem> items)
    {
        var paths = items.Select(i => i.Path!).ToList();
        Log.Write($"Dragging out {paths.Count} item(s) ({(Lab.DragOutMode == DragOutMode.PreferCopy ? "copy preferred, Shift moves" : "copy only; Shift at the start moves")}): {string.Join(", ", paths)}");

        var result = DragOut.Start(hwnd, paths, Lab.DragOutMode);

        Log.Write($"  Drag {result.Outcome}. Effect: {DataReader.Effects(result.Effect)}. Performed DropEffect: {DataReader.Effects(result.Performed)}. Logical Performed DropEffect: {DataReader.Effects(result.LogicalPerformed)}.");
        bool succeeded = result.AnyEffect != DROPEFFECT_NONE;
        bool moved = (result.AnyEffect & DROPEFFECT_MOVE) != 0;
        Log.Write($"  So: {(succeeded ? moved ? "the target says it MOVED them" : "the target says it copied (or used) them" : "nothing happened")}. {Originals(paths)}");
        if (succeeded)
        {
            // The target may still be copying or moving in the background; look again in a bit.
            var again = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            again.Tick += (_, _) => { again.Stop(); Log.Write($"  2 s later: {Originals(paths)}"); };
            again.Start();
        }

        if (succeeded && (Lab.RemoveAfterDrag || moved))
        {
            foreach (var item in items) Items.Remove(item);
            Log.Write($"  Removed {items.Count} item(s) from the shelf.");
            if (Items.Count == 0) HideIfEmptySoon();
        }
    }

    static string Originals(List<string> paths)
    {
        int present = paths.Count(p => File.Exists(p) || Directory.Exists(p));
        return present == paths.Count ? "The originals are still in place."
            : present == 0 ? "The originals are GONE from where they were (moved)."
            : $"{paths.Count - present} of {paths.Count} originals are gone.";
    }

    static ShelfItem? ItemUnder(object source)
    {
        var element = source as DependencyObject;
        while (element is not null and not ListBoxItem)
            element = element is Visual ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);
        return (element as ListBoxItem)?.DataContext as ShelfItem;
    }

    // ------------------------------------------------------------------ Keyboard focus

    // The shelf never takes focus by itself (WS_EX_NOACTIVATE), so to type into it,
    // it has to ask: drop the style, ask Windows for the foreground, and hand the focus
    // back to the app you were in when you're done. Windows allows that because you
    // just clicked the shelf (the process that got the last input may take the foreground).

    void FocusBox_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (GetForegroundWindow() == hwnd) return;
        previousForeground = GetForegroundWindow();
        SetExStyle(hwnd, 0, WS_EX_NOACTIVATE);
        bool granted = SetForegroundWindow(hwnd);
        Activate();
        FocusBox.Focus();
        Log.Write($"Shelf asked for the keyboard: {(granted ? "granted" : "REFUSED")}. You were in a {ClassName(previousForeground)} window.");
    }

    void FocusBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Log.Write($"Typed in the focus box: \"{FocusBox.Text}\"");
            SetExStyle(hwnd, WS_EX_NOACTIVATE, 0);
            if (previousForeground != 0)
            {
                bool ok = SetForegroundWindow(previousForeground);
                Log.Write($"Handed the keyboard back to the {ClassName(previousForeground)} window: {(ok ? "ok" : "REFUSED")}.");
            }
            previousForeground = 0;
            e.Handled = true;
        }
    }
}
