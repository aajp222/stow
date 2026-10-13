using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace StowLab;

/// <summary>
/// The Win32 functions, structures and constants the Lab calls directly. WPF covers
/// ordinary windows; drag-and-drop between apps, window styles, the mouse hook and
/// the displays all live down here.
/// </summary>
public static class Native
{
    // ------------------------------------------------------------------ Basics

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X, Y;
        public override readonly string ToString() => $"({X}, {Y})";
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
        public override readonly string ToString() => $"{Width}×{Height} at ({Left}, {Top})";
    }

    // ------------------------------------------------------------------ Window styles

    public const int GWL_EXSTYLE = -20;
    /// Clicks and hit-testing pass through to whatever is underneath (with WS_EX_LAYERED).
    public const long WS_EX_TRANSPARENT = 0x20;
    /// No taskbar button and not in Alt+Tab.
    public const long WS_EX_TOOLWINDOW = 0x80;
    /// Clicking the window doesn't make it the foreground window, so the app you're
    /// in keeps the focus.
    public const long WS_EX_NOACTIVATE = 0x08000000;

    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    /// Adds and removes extended window styles, then has Windows pick up the change.
    public static void SetExStyle(IntPtr hwnd, long add, long remove)
    {
        long style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr((style | add) & ~remove));
        SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }

    // ------------------------------------------------------------------ Windows and threads

    public const uint GA_ROOT = 2;

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr hwnd, StringBuilder name, int maxCount);

    public static string ClassName(IntPtr hwnd)
    {
        if (hwnd == 0) return "-";
        var name = new StringBuilder(256);
        return GetClassName(hwnd, name, name.Capacity) > 0 ? name.ToString() : "?";
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string? className, string? windowName);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);

    /// What a thread's windows are up to: which one has the mouse captured, whether
    /// it's in the middle of moving or sizing a window, and so on.
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    public const uint GUI_CARETBLINKING = 0x1, GUI_INMOVESIZE = 0x2, GUI_INMENUMODE = 0x4, GUI_SYSTEMMENUMODE = 0x8, GUI_POPUPMENUMODE = 0x10;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    // ------------------------------------------------------------------ Mouse hook and keyboard state

    public const int WH_MOUSE_LL = 14;
    public const int WM_QUIT = 0x0012, WM_SETTINGCHANGE = 0x001A, WM_DISPLAYCHANGE = 0x007E;
    public const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData, flags, time;
        public IntPtr dwExtraInfo;
    }

    public delegate IntPtr LowLevelMouseProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int hookId, LowLevelMouseProc proc, IntPtr module, uint threadId);

    [DllImport("user32.dll")]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandle(string? moduleName);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam, lParam;
        public uint time;
        public POINT pt;
        public uint lPrivate;
    }

    [DllImport("user32.dll")]
    public static extern int GetMessage(out MSG msg, IntPtr hwnd, uint filterMin, uint filterMax);

    [DllImport("user32.dll")]
    public static extern bool PostThreadMessage(uint threadId, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    public const int SM_SWAPBUTTON = 23, SM_CXDRAG = 68, SM_CYDRAG = 69;

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    public const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_SHIFT = 0x10, VK_CONTROL = 0x11;

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int virtualKey);

    /// Whether a key or mouse button is down right now. This asks the hardware state
    /// rather than WPF's Keyboard class, which only knows about keys pressed while one
    /// of our windows had the focus, and the shelf usually doesn't.
    public static bool IsKeyDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    /// The button people think of as the left one. GetAsyncKeyState reports physical
    /// buttons, so with the buttons swapped in Settings that's the right-hand one.
    public static int PrimaryButton => GetSystemMetrics(SM_SWAPBUTTON) != 0 ? VK_RBUTTON : VK_LBUTTON;

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CURSORINFO info);

    [DllImport("user32.dll")]
    public static extern IntPtr LoadCursor(IntPtr instance, IntPtr cursorId);

    // ------------------------------------------------------------------ Displays

    public const uint MONITOR_DEFAULTTONEAREST = 2;
    const int MDT_EFFECTIVE_DPI = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor, rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT point, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT bounds, IntPtr data);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

    [DllImport("shcore.dll")]
    static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    public static List<IntPtr> Monitors()
    {
        var monitors = new List<IntPtr>();
        MonitorEnumProc proc = (IntPtr monitor, IntPtr hdc, ref RECT bounds, IntPtr data) =>
        {
            monitors.Add(monitor);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
        GC.KeepAlive(proc);
        return monitors;
    }

    public static MONITORINFO MonitorInfo(IntPtr monitor)
    {
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(monitor, ref info);
        return info;
    }

    /// The display's scaling as dots per inch: 96 is 100%, 144 is 150%.
    public static uint Dpi(IntPtr monitor) =>
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out uint dpi, out _) == 0 ? dpi : 96;

    // ------------------------------------------------------------------ DWM (window backgrounds and corners)

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMWCP_ROUND = 2;
    /// Backdrop types: no backdrop, Mica (for main windows) and Acrylic (for menus and flyouts).
    public const int DWMSBT_NONE = 1, DWMSBT_MAINWINDOW = 2, DWMSBT_TRANSIENTWINDOW = 3;

    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS { public int Left, Right, Top, Bottom; }

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

    // ------------------------------------------------------------------ Clipboard formats and memory

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint RegisterClipboardFormat(string name);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClipboardFormatName(uint format, StringBuilder name, int maxCount);

    public const uint GMEM_MOVEABLE = 0x2, GMEM_ZEROINIT = 0x40;

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalLock(IntPtr memory);

    [DllImport("kernel32.dll")]
    public static extern bool GlobalUnlock(IntPtr memory);

    [DllImport("kernel32.dll")]
    public static extern UIntPtr GlobalSize(IntPtr memory);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalFree(IntPtr memory);

    // ------------------------------------------------------------------ OLE drag-and-drop

    /// Sets up OLE (which drag-and-drop runs on) for the calling thread. Returns 1
    /// (S_FALSE) if it already was.
    [DllImport("ole32.dll")]
    public static extern int OleInitialize(IntPtr reserved);

    public const int DROPEFFECT_NONE = 0, DROPEFFECT_COPY = 1, DROPEFFECT_MOVE = 2, DROPEFFECT_LINK = 4;
    public const int DRAGDROP_S_DROP = 0x00040100, DRAGDROP_S_CANCEL = 0x00040101;
    /// Drop description icons (the badge Windows draws next to a dragged item's picture).
    public const int DROPIMAGE_INVALID = -1, DROPIMAGE_COPY = 1;

    [DllImport("ole32.dll")]
    public static extern int RegisterDragDrop(IntPtr hwnd, IDropTarget target);

    [DllImport("ole32.dll")]
    public static extern int RevokeDragDrop(IntPtr hwnd);

    [DllImport("ole32.dll")]
    public static extern void ReleaseStgMedium(ref STGMEDIUM medium);

    public const uint STGM_READWRITE = 0x2, STGM_SHARE_EXCLUSIVE = 0x10, STGM_CREATE = 0x1000;

    [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
    public static extern int StgCreateDocfile(string name, uint mode, uint reserved, out IStorage storage);

    // ------------------------------------------------------------------ Shell

    /// Makes an empty data object owned by the shell. See DragOut for why it beats WPF's.
    [DllImport("shell32.dll")]
    public static extern int SHCreateDataObject(IntPtr folder, uint count, IntPtr items,
        [MarshalAs(UnmanagedType.Interface)] IDataObject? inner, ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IDataObject dataObject);

    /// Runs a drag-and-drop the way File Explorer does. With no drop source passed
    /// (IntPtr.Zero), the shell supplies a standard one: Esc cancels, letting go drops.
    [DllImport("shell32.dll")]
    public static extern int SHDoDragDrop(IntPtr hwnd, [MarshalAs(UnmanagedType.Interface)] IDataObject data,
        IntPtr dropSource, int allowedEffects, out int effect);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint DragQueryFile(IntPtr drop, uint index, StringBuilder? file, uint size);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    public const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);
}
