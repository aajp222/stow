using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace StowLab;

// COM interfaces for drag-and-drop that .NET doesn't define. The GUIDs and the order
// of the methods come from Windows' own headers (oleidl.h and shobjidl_core.h): COM
// finds a method by its position in the interface, so the order must match exactly.

/// What a window implements to take drops. OLE calls it as a drag enters, moves over,
/// leaves, or is dropped on the window it's registered for (RegisterDragDrop).
[ComImport, Guid("00000122-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDropTarget
{
    [PreserveSig] int DragEnter([MarshalAs(UnmanagedType.Interface)] IDataObject data, int keyState, Native.POINT point, ref int effect);
    [PreserveSig] int DragOver(int keyState, Native.POINT point, ref int effect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop([MarshalAs(UnmanagedType.Interface)] IDataObject data, int keyState, Native.POINT point, ref int effect);
}

/// The shell's helper that draws the dragged item's picture over a drop target.
/// Without it, the picture File Explorer shows under the pointer vanishes as soon
/// as it crosses into one of our windows.
[ComImport, Guid("4657278B-411B-11D2-839A-00C04FD918D0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDropTargetHelper
{
    void DragEnter(IntPtr hwndTarget, [MarshalAs(UnmanagedType.Interface)] IDataObject data, ref Native.POINT point, int effect);
    void DragLeave();
    void DragOver(ref Native.POINT point, int effect);
    void Drop([MarshalAs(UnmanagedType.Interface)] IDataObject data, ref Native.POINT point, int effect);
    void Show([MarshalAs(UnmanagedType.Bool)] bool show);
}

/// The class that implements IDropTargetHelper (CLSID_DragDropHelper). `new` on it
/// asks COM to create one.
[ComImport, Guid("4657278A-411B-11D2-839A-00C04FD918D0")]
class DragDropHelper { }

/// A structured storage (a "file system inside a file"). Classic Outlook hands over
/// a dragged email this way; copying it into a new compound file makes a .msg file.
/// Only CopyTo and Commit are called. The methods before them are placeholders that
/// keep the positions right, and the ones after Commit can be left out entirely.
[ComImport, Guid("0000000B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IStorage
{
    void CreateStream();
    void OpenStream();
    void CreateStorage();
    void OpenStorage();
    void CopyTo(uint excludeCount, IntPtr excludeIids, IntPtr excludeNames, [MarshalAs(UnmanagedType.Interface)] IStorage destination);
    void MoveElementTo();
    void Commit(uint flags);
}
