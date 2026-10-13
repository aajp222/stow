using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using static StowLab.Native;

namespace StowLab;

/// <summary>
/// A window's drop target, registered with OLE directly rather than through WPF.
///
/// WPF's drag-and-drop hides the source app's raw data object, and Stow needs it:
/// the bytes of virtual files (Outlook attachments, browser images) are asked for
/// one file at a time by index, which WPF can't do. Going direct also lets the shell
/// keep drawing the dragged item's picture over our windows (IDropTargetHelper).
///
/// Each handler gets the effects the source allows (copy, move, link) and returns
/// the one this window would do, which sets the pointer's badge.
/// </summary>
[ComVisible(true)]
public sealed class OleDropTarget : IDropTarget
{
    public delegate int DragHandler(IDataObject data, POINT point, int keyState, int allowed);

    public DragHandler? Enter;
    public Func<POINT, int, int, int>? Over;
    public Action? Leave;
    public DragHandler? Dropped;

    readonly IntPtr hwnd;
    readonly string name;
    readonly IDropTargetHelper? helper;

    OleDropTarget(IntPtr hwnd, string name)
    {
        this.hwnd = hwnd;
        this.name = name;
        try { helper = (IDropTargetHelper)new DragDropHelper(); }
        catch (Exception e) { Log.Write($"No drag picture helper for the {name}: {e.Message}"); }
    }

    public static OleDropTarget Register(IntPtr hwnd, string name)
    {
        var target = new OleDropTarget(hwnd, name);
        // WPF registers its own drop target on the windows it creates. Only one is
        // allowed per window, so take WPF's out first. (If WPF hadn't registered one,
        // this fails harmlessly.)
        RevokeDragDrop(hwnd);
        int result = RegisterDragDrop(hwnd, target);
        if (result != 0) Log.Write($"Couldn't make the {name} a drop target: error 0x{result:X8}");
        return target;
    }

    int IDropTarget.DragEnter(IDataObject data, int keyState, POINT point, ref int effect)
    {
        int allowed = effect;
        effect = Run(() => Enter?.Invoke(data, point, keyState, allowed) ?? DROPEFFECT_NONE);
        try { helper?.DragEnter(hwnd, data, ref point, effect); } catch { }
        return 0;
    }

    int IDropTarget.DragOver(int keyState, POINT point, ref int effect)
    {
        int allowed = effect;
        effect = Run(() => Over?.Invoke(point, keyState, allowed) ?? DROPEFFECT_NONE);
        try { helper?.DragOver(ref point, effect); } catch { }
        return 0;
    }

    int IDropTarget.DragLeave()
    {
        try { helper?.DragLeave(); } catch { }
        Run(() => { Leave?.Invoke(); return 0; });
        return 0;
    }

    int IDropTarget.Drop(IDataObject data, int keyState, POINT point, ref int effect)
    {
        int allowed = effect;
        // Let the helper put the drag picture away first, so it doesn't hang around
        // while a big file is being saved.
        try { helper?.Drop(data, ref point, allowed); } catch { }
        effect = Run(() => Dropped?.Invoke(data, point, keyState, allowed) ?? DROPEFFECT_NONE);
        return 0;
    }

    /// An exception mustn't escape into OLE (it would end the other app's drag in an
    /// odd state), so log it and report "no drop" instead.
    int Run(Func<int> handler)
    {
        try { return handler(); }
        catch (Exception e)
        {
            Log.Write($"Error in the {name}'s drop handling: {e}");
            return DROPEFFECT_NONE;
        }
    }
}
