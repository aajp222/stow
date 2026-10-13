using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using static StowLab.Native;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace StowLab;

/// <summary>
/// An invisible 2-pixel strip along the left or right edge of a display that takes
/// part in drag-and-drop, so Stow finds out when a drag reaches the side of the screen
/// and what's being dragged.
///
/// It's a layered window (AllowsTransparency) painted at 1/255 opacity: invisible, but
/// solid enough for Windows to count it as under the pointer. Normally it also has
/// WS_EX_TRANSPARENT, so clicks fall straight through to what's underneath (a maximised
/// window's scroll bar, say). Only while a press-and-drag is under way is that turned
/// off (Armed), so that OLE, looking for the window under a drag, finds the strip.
/// </summary>
sealed class EdgeStrip : Window
{
    const int ThicknessPixels = 2;
    static readonly Brush Invisible = Frozen(Color.FromArgb(1, 0, 0, 0));
    static readonly Brush Tinted = Frozen(Color.FromArgb(0xC0, 0xFF, 0x3B, 0x30));

    /// A drag touched the strip: where, and whether it's something the shelf can take.
    public event Action<POINT, bool>? DragTouched;

    readonly RECT display;
    readonly bool leftEdge;
    IntPtr hwnd;
    OleDropTarget? dropTarget;

    public string Side => leftEdge ? "left" : "right";

    public EdgeStrip(RECT display, bool leftEdge)
    {
        this.display = display;
        this.leftEdge = leftEdge;
        Title = $"Stow Lab edge strip ({Side})";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Width = Height = 2;
        UpdateTint();
        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            SetExStyle(hwnd, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, 0);
            dropTarget = OleDropTarget.Register(hwnd, $"{Side} edge strip");
            dropTarget.Enter = OnDragEnter;
            dropTarget.Over = (_, _, _) => DROPEFFECT_NONE;
        };
    }

    /// Puts the strip in place, in real pixels. Called twice after showing: if the
    /// display is scaled differently from where WPF first made the window, Windows
    /// rescales it after the first move, and the second puts the size back.
    public void Place()
    {
        int x = leftEdge ? display.Left : display.Right - ThicknessPixels;
        SetWindowPos(hwnd, HWND_TOPMOST, x, display.Top, ThicknessPixels, display.Height, SWP_NOACTIVATE);
    }

    public bool Armed
    {
        set
        {
            if (hwnd == 0) return;
            if (value)
            {
                SetExStyle(hwnd, 0, WS_EX_TRANSPARENT);
                Place(); // also back on top of any other always-on-top window
            }
            else
            {
                SetExStyle(hwnd, WS_EX_TRANSPARENT, 0);
            }
        }
    }

    public void UpdateTint() => Background = Lab.ShowStrips ? Tinted : Invisible;

    int OnDragEnter(ComDataObject data, POINT point, int keyState, int allowed)
    {
        if (DragOut.InProgress) return DROPEFFECT_NONE; // the shelf's own drag
        bool accepted = DataReader.Accepts(data);
        Log.Write($"Drag reached the {Side} edge at {point}: {(accepted ? "the shelf can take it" : "nothing the shelf takes")}. Formats: {DataReader.DescribeFormats(data)}");
        DragTouched?.Invoke(point, accepted);
        return DROPEFFECT_NONE; // the strip itself never takes the drop
    }

    static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
