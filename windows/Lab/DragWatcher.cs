using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using static StowLab.Native;

namespace StowLab;

/// Where a press-and-drag started: the window under the pointer and who owns it.
sealed record DragGesture(POINT Start, IntPtr Window, uint Thread, uint ProcessId, string ProcessName, string WindowClass)
{
    public bool InStow => ProcessId == Environment.ProcessId;
}

/// <summary>
/// Notices drags anywhere on the PC: the Windows counterpart of the Mac's DragMonitor.
///
/// Windows has no shared drag pasteboard to watch. During drag-and-drop, the source
/// app hands its data straight to whichever window is under the pointer. So this
/// watches the mouse instead, with a low-level mouse hook, which sees every mouse
/// event on the desktop. Windows doesn't ask the user's permission for one.
///
/// A press-and-drag could be a file being dragged, but also a window being moved or
/// text being selected. This class reports any press-and-drag (GestureStarted), which
/// switches on the edge strips: those take part in real drag-and-drop, so only a real
/// drag lights them up. It also logs the clues that might tell the cases apart right
/// away, for the "as soon as you drag" guess.
/// </summary>
sealed class DragWatcher : IDisposable
{
    /// The button went down outside Stow and the pointer has moved far enough to be a drag.
    public event Action<DragGesture>? GestureStarted;
    /// The clues say a drag-and-drop is under way (the experimental guess).
    public event Action<POINT>? LooksLikeDragAndDrop;
    public event Action<POINT>? Shaken;
    /// The button came up after a press-and-drag. True if it started in Stow.
    public event Action<bool>? ButtonReleased;

    readonly Dispatcher dispatcher;
    readonly DispatcherTimer timer;

    // The hook runs on its own thread with its own message loop. Windows waits for the
    // hook before passing each mouse event on, and quietly removes hooks that keep it
    // waiting, so the hook must never sit behind a busy UI thread (saving a big file
    // from a drop, say). It only notes what happened and passes it to the UI thread.
    readonly Thread hookThread;
    uint hookThreadId;
    IntPtr hook;
    LowLevelMouseProc? hookProc; // kept in a field: Windows calls it, and the GC mustn't collect it

    // Hook-thread state.
    bool hookButtonDown, hookPastThreshold;
    POINT hookDownPoint;
    readonly int dragWidth, dragHeight;

    // UI-thread state for the current press.
    DragGesture? gesture;
    bool pastThreshold, guessed, shaken;
    string lastClues = "";
    readonly Stopwatch clock = new();
    readonly ShakeDetector shake = new();
    readonly Dictionary<IntPtr, string> standardCursors = new();

    public DragWatcher(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        // How far the pointer must move with the button down before Windows calls it a drag.
        dragWidth = Math.Max(GetSystemMetrics(SM_CXDRAG), 1);
        dragHeight = Math.Max(GetSystemMetrics(SM_CYDRAG), 1);

        foreach (var (id, cursorName) in new[] { (32512, "arrow"), (32513, "text"), (32514, "wait"), (32515, "cross"), (32646, "move"), (32648, "no"), (32649, "hand"), (32650, "busy") })
            standardCursors[LoadCursor(IntPtr.Zero, id)] = cursorName;

        // Sixty times a second while the button is down, like the Mac's DragMonitor.
        timer = new DispatcherTimer(DispatcherPriority.Input, dispatcher) { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) => Tick();

        using var ready = new ManualResetEventSlim();
        hookThread = new Thread(() => RunHook(ready)) { IsBackground = true, Name = "Mouse hook" };
        hookThread.Start();
        ready.Wait();
    }

    public void Dispose()
    {
        timer.Stop();
        PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }

    void RunHook(ManualResetEventSlim ready)
    {
        hookThreadId = GetCurrentThreadId();
        hookProc = HookProc;
        hook = SetWindowsHookEx(WH_MOUSE_LL, hookProc, GetModuleHandle(null), 0);
        int error = Marshal.GetLastWin32Error();
        ready.Set();
        Log.Write(hook == 0 ? $"Mouse hook FAILED to install (error {error})." : "Mouse hook installed.");
        // Windows calls the hook from inside GetMessage, so the thread just keeps
        // waiting for messages until Dispose posts WM_QUIT.
        while (GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
        if (hook != 0) UnhookWindowsHookEx(hook);
    }

    /// On the hook thread: note the event, hand anything interesting to the UI thread, return fast.
    IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            switch ((int)wParam)
            {
                case WM_LBUTTONDOWN:
                    hookButtonDown = true;
                    hookPastThreshold = false;
                    hookDownPoint = info.pt;
                    var point = info.pt;
                    dispatcher.InvokeAsync(() => ButtonDown(point));
                    break;
                case WM_MOUSEMOVE:
                    if (hookButtonDown && !hookPastThreshold
                        && (Math.Abs(info.pt.X - hookDownPoint.X) > dragWidth || Math.Abs(info.pt.Y - hookDownPoint.Y) > dragHeight))
                    {
                        hookPastThreshold = true;
                        dispatcher.InvokeAsync(PassedThreshold);
                    }
                    break;
                case WM_LBUTTONUP:
                    if (hookButtonDown)
                    {
                        hookButtonDown = false;
                        dispatcher.InvokeAsync(ButtonUp);
                    }
                    break;
            }
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    void ButtonDown(POINT point)
    {
        IntPtr window = WindowFromPoint(point);
        uint thread = GetWindowThreadProcessId(window, out uint processId);
        gesture = new DragGesture(point, window, thread, processId, ProcessName(processId), ClassName(GetAncestor(window, GA_ROOT)));
        pastThreshold = guessed = shaken = false;
        lastClues = "";
        shake.Reset();
        timer.Start();
    }

    void PassedThreshold()
    {
        if (gesture is null || pastThreshold) return;
        pastThreshold = true;
        clock.Restart();
        if (gesture.InStow) return;
        Log.Write($"Press-and-drag started in {gesture.ProcessName} (window class {gesture.WindowClass}).");
        GestureStarted?.Invoke(gesture);
    }

    void Tick()
    {
        // Also catches a button release the hook didn't report, as the Mac version does.
        if (!IsKeyDown(PrimaryButton))
        {
            ButtonUp();
            return;
        }
        if (gesture is null || !pastThreshold || gesture.InStow) return;

        GetCursorPos(out var pointer);
        LogClues(pointer);

        double dpiScale = Dpi(MonitorFromPoint(pointer, MONITOR_DEFAULTTONEAREST)) / 96.0;
        if (!shaken && shake.Add(pointer.X / dpiScale, clock.Elapsed.TotalSeconds))
        {
            shaken = true;
            Log.Write("  Shake detected.");
            Shaken?.Invoke(pointer);
        }
    }

    void ButtonUp()
    {
        if (!timer.IsEnabled) return; // already handled (the hook and the timer can both report it)
        timer.Stop();
        bool wasDrag = pastThreshold && gesture is not null;
        bool inStow = gesture?.InStow ?? false;
        gesture = null;
        pastThreshold = false;
        if (!wasDrag) return;
        if (!inStow) Log.Write($"Button released after {clock.ElapsedMilliseconds} ms.");
        ButtonReleased?.Invoke(inStow);
    }

    /// Logs the clues every time they change, so the log shows how each kind of
    /// press-and-drag looks from outside:
    /// - which window in the source app has the mouse captured, and whether that
    ///   thread is moving or sizing a window (Windows' own GUI_INMOVESIZE flag);
    /// - whether the shell's drag picture window ("SysDragImage") is showing;
    /// - which pointer is on screen.
    void LogClues(POINT pointer)
    {
        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        bool known = GetGUIThreadInfo(gesture!.Thread, ref info);
        string capture = known ? ClassName(info.hwndCapture) : "?";
        bool movingWindow = known && (info.flags & GUI_INMOVESIZE) != 0;

        IntPtr picture = FindWindow("SysDragImage", null);
        string pictureState = picture == 0 ? "none" : IsWindowVisible(picture) ? "showing" : "hidden";

        string clues = $"capture={capture} flags={(known ? Flags(info.flags) : "?")} dragPicture={pictureState} pointer={CursorName()}";
        if (clues != lastClues)
        {
            lastClues = clues;
            Log.Write($"  +{clock.ElapsedMilliseconds,4} ms  {clues}  (over {ClassName(GetAncestor(WindowFromPoint(pointer), GA_ROOT))})");
        }

        // The guess: OLE runs a drag-and-drop with the mouse captured by its hidden
        // per-thread window (class CLIPBRDWNDCLASS), and the shell shows its drag picture
        // window. Moving a window shows neither; selecting text captures the mouse in the
        // app's own window. The log says whether that holds up.
        bool looksLikeDragAndDrop = !movingWindow && (capture == "CLIPBRDWNDCLASS" || pictureState == "showing");
        if (!guessed && looksLikeDragAndDrop)
        {
            guessed = true;
            Log.Write($"  Guess: this looks like a drag-and-drop ({(capture == "CLIPBRDWNDCLASS" ? "OLE has the mouse" : "drag picture showing")}).");
            LooksLikeDragAndDrop?.Invoke(pointer);
        }
    }

    string CursorName()
    {
        var info = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref info)) return "?";
        return standardCursors.TryGetValue(info.hCursor, out var name) ? name : $"other:{info.hCursor:X}";
    }

    static string Flags(uint flags)
    {
        var names = new List<string>();
        if ((flags & GUI_CARETBLINKING) != 0) names.Add("caret");
        if ((flags & GUI_INMOVESIZE) != 0) names.Add("MOVING-WINDOW");
        if ((flags & GUI_INMENUMODE) != 0) names.Add("menu");
        if ((flags & GUI_SYSTEMMENUMODE) != 0) names.Add("systemmenu");
        if ((flags & GUI_POPUPMENUMODE) != 0) names.Add("popupmenu");
        return names.Count == 0 ? "none" : string.Join("+", names);
    }

    static string ProcessName(uint processId)
    {
        try
        {
            using var process = Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch
        {
            return $"process {processId}"; // e.g. an app running as administrator
        }
    }
}

/// <summary>
/// Spots a shake: the pointer swinging left and right several times in quick
/// succession, like shaking something loose. The same rule as the Mac's ShakeDetector.
/// </summary>
sealed class ShakeDetector
{
    /// How far a swing must travel to count, in DIPs (the Mac's points).
    public double MinimumSwing = 25;
    /// How many changes of direction make a shake...
    public int RequiredTurns = 3;
    /// ...and within how many seconds.
    public double TimeWindow = 1.0;

    double? lastX;
    /// -1 moving left, 1 moving right, 0 not yet known.
    double direction;
    /// Where the current swing started.
    double swingStartX;
    /// When each recent change of direction happened.
    readonly List<double> turns = new();

    public void Reset()
    {
        lastX = null;
        direction = 0;
        turns.Clear();
    }

    /// Adds a pointer position seen at `time` (seconds, any steady clock). Returns true
    /// once the recent movement is a shake.
    public bool Add(double x, double time)
    {
        if (lastX is not double previousX)
        {
            lastX = x;
            swingStartX = x;
            return false;
        }
        lastX = x;
        double dx = x - previousX;
        if (Math.Abs(dx) < 1) return false;
        double newDirection = dx > 0 ? 1 : -1;
        if (newDirection != direction)
        {
            // The swing that just ended ran from swingStartX to previousX.
            if (direction != 0 && Math.Abs(previousX - swingStartX) >= MinimumSwing) turns.Add(time);
            direction = newDirection;
            swingStartX = previousX;
        }
        turns.RemoveAll(t => time - t > TimeWindow);
        return turns.Count >= RequiredTurns;
    }
}
