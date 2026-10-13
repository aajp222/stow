using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using static StowLab.Native;

namespace StowLab;

/// The two ways the Lab tries to make a drag out copy by default and move with Shift.
enum DragOutMode
{
    /// Allow copy and move, and say copy is preferred ("Preferred DropEffect").
    /// Shift during the drag moves. This is what Stow wants, if targets honour it.
    PreferCopy,
    /// Allow copy only, unless Shift is down as the drag starts; then allow move only.
    CopyOnlyUnlessShift,
}

/// <summary>Drags files from the shelf into other apps.</summary>
static class DragOut
{
    /// True while one of the shelf's own drags is under way, so the shelf and the
    /// edge strips ignore it (the Mac version ignores drags that start in Stow too).
    public static bool InProgress { get; private set; }

    public sealed record Result(int HResult, int Effect, int? Performed, int? LogicalPerformed)
    {
        /// Everything the target says it did, from any of the three places it can say it.
        public int AnyEffect => Effect | (Performed ?? 0) | (LogicalPerformed ?? 0);

        public string Outcome => HResult switch
        {
            DRAGDROP_S_DROP => "dropped",
            DRAGDROP_S_CANCEL => "cancelled",
            _ => $"0x{HResult:X8}",
        };
    }

    public static Result Start(IntPtr hwnd, IReadOnlyList<string> paths, DragOutMode mode)
    {
        // An empty data object made by the shell, not WPF's DataObject. The shell's takes
        // any format a drop target writes back into it, and File Explorer uses that to
        // report a move it did itself ("Performed DropEffect"); the shell's drag pictures
        // and drop descriptions rely on it too.
        var iid = typeof(IDataObject).GUID;
        Marshal.ThrowExceptionForHR(SHCreateDataObject(IntPtr.Zero, 0, IntPtr.Zero, null, ref iid, out var data));
        try
        {
            // CF_HDROP: the list of paths. File Explorer, browsers, Outlook, Mail, Slack and
            // Discord all read it.
            DataReader.SetMemory(data, Formats.CF_HDROP, DropFiles(paths));

            int allowed;
            if (mode == DragOutMode.PreferCopy)
            {
                // Without this, File Explorer moves files dropped on the same drive and
                // copies them to another one, which would move the originals out from
                // under the shelf's references.
                DataReader.SetMemory(data, Formats.PreferredDropEffect, DataReader.Memory(DROPEFFECT_COPY));
                allowed = DROPEFFECT_COPY | DROPEFFECT_MOVE;
            }
            else
            {
                allowed = IsKeyDown(VK_SHIFT) ? DROPEFFECT_MOVE : DROPEFFECT_COPY;
            }

            // SHDoDragDrop runs the drag and returns once it's over: dropped, refused or
            // cancelled with Esc. Meanwhile the target app does the copying or moving.
            int result, effect;
            InProgress = true;
            try { result = SHDoDragDrop(hwnd, data, IntPtr.Zero, allowed, out effect); }
            finally { InProgress = false; }

            // When File Explorer moves files within a drive it does the move itself and
            // reports "none" here, writing what it really did into the data object
            // instead. So read those back too.
            return new Result(result, effect & 7,
                DataReader.ReadInt(data, Formats.PerformedDropEffect),
                DataReader.ReadInt(data, Formats.LogicalPerformedDropEffect));
        }
        finally
        {
            Marshal.ReleaseComObject(data);
        }
    }

    /// DROPFILES: a 20-byte header, then the paths as UTF-16, each ending in a null
    /// character, with one more null at the end of the list.
    static IntPtr DropFiles(IReadOnlyList<string> paths)
    {
        byte[] list = Encoding.Unicode.GetBytes(string.Join("\0", paths) + "\0\0");
        var bytes = new byte[20 + list.Length];
        BitConverter.GetBytes(20).CopyTo(bytes, 0);  // pFiles: where the list starts
        BitConverter.GetBytes(1).CopyTo(bytes, 16);  // fWide: the paths are UTF-16
        list.CopyTo(bytes, 20);
        return DataReader.Memory(bytes);
    }
}
