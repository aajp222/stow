using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using static StowLab.Native;

namespace StowLab;

/// <summary>
/// Clipboard formats: the labels on the pieces of data in a drag (or on the
/// clipboard). A few are numbered constants from the earliest Windows; the rest are
/// registered by name, and Windows hands out the same number for a name to every app
/// that asks.
/// </summary>
static class Formats
{
    public const short CF_BITMAP = 2, CF_DIB = 8, CF_UNICODETEXT = 13, CF_HDROP = 15, CF_DIBV5 = 17;

    /// Files that don't exist on disk yet (an Outlook attachment, an image in a
    /// browser, a file inside a zip): their names and sizes. The bytes of each come
    /// separately as FileContents, asked for one file at a time by index. This is
    /// Windows' version of the Mac's file promises.
    public static readonly short FileGroupDescriptorW = Register("FileGroupDescriptorW");
    public static readonly short FileGroupDescriptor = Register("FileGroupDescriptor");
    public static readonly short FileContents = Register("FileContents");
    /// Shell items by their internal IDs; some (Control Panel items, phones) have no path.
    public static readonly short ShellIdList = Register("Shell IDList Array");
    public static readonly short UrlW = Register("UniformResourceLocatorW");
    public static readonly short Url = Register("UniformResourceLocator");
    public static readonly short Png = Register("PNG");
    /// Set by the source: whether it would rather the target copied or moved.
    public static readonly short PreferredDropEffect = Register("Preferred DropEffect");
    /// Written back into the source's data by the target to say what it really did.
    public static readonly short PerformedDropEffect = Register("Performed DropEffect");
    public static readonly short LogicalPerformedDropEffect = Register("Logical Performed DropEffect");
    /// Set by the target: the "Copy to Documents"-style label under the dragged picture.
    public static readonly short DropDescription = Register("DropDescription");

    static short Register(string name) => unchecked((short)RegisterClipboardFormat(name));

    static readonly Dictionary<short, string> builtIn = new()
    {
        [1] = "CF_TEXT", [2] = "CF_BITMAP", [3] = "CF_METAFILEPICT", [7] = "CF_OEMTEXT", [8] = "CF_DIB",
        [13] = "CF_UNICODETEXT", [14] = "CF_ENHMETAFILE", [15] = "CF_HDROP", [16] = "CF_LOCALE", [17] = "CF_DIBV5",
    };

    public static string Name(short format)
    {
        if (builtIn.TryGetValue(format, out var name)) return name;
        var buffer = new StringBuilder(256);
        return GetClipboardFormatName((ushort)format, buffer, buffer.Capacity) > 0 ? buffer.ToString() : $"#{(ushort)format}";
    }
}

/// <summary>
/// Reads what's in a drag, straight from the source app's COM data object, and
/// writes the few things a drag source or target sends back.
/// </summary>
static class DataReader
{
    const TYMED AnyMedium = TYMED.TYMED_HGLOBAL | TYMED.TYMED_ISTREAM | TYMED.TYMED_ISTORAGE | TYMED.TYMED_GDI;

    public static FORMATETC Format(short format, TYMED medium, int index = -1) => new()
    {
        cfFormat = format,
        ptd = IntPtr.Zero,
        dwAspect = DVASPECT.DVASPECT_CONTENT,
        lindex = index,
        tymed = medium,
    };

    public static bool Has(IDataObject data, short format, TYMED medium = AnyMedium)
    {
        var request = Format(format, medium);
        try { return data.QueryGetData(ref request) == 0; }
        catch { return false; }
    }

    /// The same rule as the Mac: files, folders, file promises, links, text and images.
    public static bool Accepts(IDataObject data) =>
        Has(data, Formats.CF_HDROP) || Has(data, Formats.FileGroupDescriptorW) || Has(data, Formats.ShellIdList)
        || Has(data, Formats.UrlW) || Has(data, Formats.Url) || Has(data, Formats.CF_UNICODETEXT)
        || Has(data, Formats.Png) || Has(data, Formats.CF_DIBV5) || Has(data, Formats.CF_DIB);

    /// Every format the source offers, for the log.
    public static string DescribeFormats(IDataObject data)
    {
        try
        {
            var formats = data.EnumFormatEtc(DATADIR.DATADIR_GET);
            var one = new FORMATETC[1];
            var fetched = new int[1];
            var names = new List<string>();
            while (formats.Next(1, one, fetched) == 0 && fetched[0] == 1)
            {
                string index = one[0].lindex == -1 ? "" : $" #{one[0].lindex}";
                names.Add($"{Formats.Name(one[0].cfFormat)} [{Media(one[0].tymed)}{index}]");
            }
            return names.Count == 0 ? "(none listed)" : string.Join(", ", names);
        }
        catch (Exception e)
        {
            return $"(the source wouldn't list its formats: {e.Message})";
        }
    }

    static string Media(TYMED media)
    {
        var names = new List<string>();
        if (media.HasFlag(TYMED.TYMED_HGLOBAL)) names.Add("memory");
        if (media.HasFlag(TYMED.TYMED_FILE)) names.Add("file");
        if (media.HasFlag(TYMED.TYMED_ISTREAM)) names.Add("stream");
        if (media.HasFlag(TYMED.TYMED_ISTORAGE)) names.Add("storage");
        if (media.HasFlag(TYMED.TYMED_GDI)) names.Add("bitmap");
        if (media.HasFlag(TYMED.TYMED_MFPICT) || media.HasFlag(TYMED.TYMED_ENHMF)) names.Add("metafile");
        return string.Join("|", names);
    }

    public static string Effects(int? effect)
    {
        if (effect is not int e) return "not set";
        e &= DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK;
        if (e == 0) return "none";
        var names = new List<string>();
        if ((e & DROPEFFECT_COPY) != 0) names.Add("copy");
        if ((e & DROPEFFECT_MOVE) != 0) names.Add("move");
        if ((e & DROPEFFECT_LINK) != 0) names.Add("link");
        return string.Join("+", names);
    }

    // ------------------------------------------------------------------ Paths, text

    /// CF_HDROP: the paths of real files and folders.
    public static string[] FilePaths(IDataObject data)
    {
        var request = Format(Formats.CF_HDROP, TYMED.TYMED_HGLOBAL);
        data.GetData(ref request, out var medium);
        try
        {
            uint count = DragQueryFile(medium.unionmember, 0xFFFFFFFF, null, 0);
            var paths = new string[count];
            for (uint i = 0; i < count; i++)
            {
                uint length = DragQueryFile(medium.unionmember, i, null, 0);
                var path = new StringBuilder((int)length + 1);
                DragQueryFile(medium.unionmember, i, path, (uint)path.Capacity);
                paths[i] = path.ToString();
            }
            return paths;
        }
        finally
        {
            ReleaseStgMedium(ref medium);
        }
    }

    /// Text in a memory block: UTF-16 for the "W" formats, the system code page otherwise.
    public static string? Text(IDataObject data, short format, bool unicode)
    {
        if (!Has(data, format, TYMED.TYMED_HGLOBAL)) return null;
        try
        {
            var request = Format(format, TYMED.TYMED_HGLOBAL);
            data.GetData(ref request, out var medium);
            try
            {
                int size = (int)GlobalSize(medium.unionmember);
                IntPtr pointer = GlobalLock(medium.unionmember);
                try
                {
                    string? text = unicode ? Marshal.PtrToStringUni(pointer, size / 2) : Marshal.PtrToStringAnsi(pointer, size);
                    int end = text?.IndexOf('\0') ?? -1;
                    return end >= 0 ? text![..end] : text;
                }
                finally { GlobalUnlock(medium.unionmember); }
            }
            finally { ReleaseStgMedium(ref medium); }
        }
        catch { return null; }
    }

    // ------------------------------------------------------------------ Virtual files

    const uint FD_FILESIZE = 0x40;
    const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    const uint FD_ATTRIBUTES = 0x4;

    public sealed record VirtualFile(string Name, bool IsFolder, long? Size);

    /// Parses FILEGROUPDESCRIPTORW: a count, then one 592-byte FILEDESCRIPTORW per file.
    public static List<VirtualFile> VirtualFiles(IDataObject data)
    {
        var request = Format(Formats.FileGroupDescriptorW, TYMED.TYMED_HGLOBAL);
        data.GetData(ref request, out var medium);
        try
        {
            IntPtr group = GlobalLock(medium.unionmember);
            try
            {
                int count = Marshal.ReadInt32(group);
                var files = new List<VirtualFile>(count);
                for (int i = 0; i < count; i++)
                {
                    // FILEDESCRIPTORW: flags @0, clsid @4, sizel @20, pointl @28, attributes @36,
                    // three FILETIMEs @40/48/56, size high @64, size low @68, name @72 (260 chars).
                    IntPtr descriptor = group + 4 + i * 592;
                    uint flags = (uint)Marshal.ReadInt32(descriptor, 0);
                    uint attributes = (uint)Marshal.ReadInt32(descriptor, 36);
                    long size = ((long)(uint)Marshal.ReadInt32(descriptor, 64) << 32) | (uint)Marshal.ReadInt32(descriptor, 68);
                    string name = Marshal.PtrToStringUni(descriptor + 72) ?? "";
                    bool isFolder = (flags & FD_ATTRIBUTES) != 0 && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    files.Add(new VirtualFile(name, isFolder, (flags & FD_FILESIZE) != 0 ? size : null));
                }
                return files;
            }
            finally { GlobalUnlock(medium.unionmember); }
        }
        finally
        {
            ReleaseStgMedium(ref medium);
        }
    }

    /// Saves every virtual file in a drop under `folder` and returns the top-level
    /// items (a dragged folder's files arrive one by one with paths like "Folder\a.txt").
    public static List<string> SaveVirtualFiles(IDataObject data, string folder)
    {
        var files = VirtualFiles(data);
        Log.Write($"  {files.Count} virtual file(s): {string.Join(", ", files.Select(f => f.Name + (f.IsFolder ? "\\" : "")))}");
        Directory.CreateDirectory(folder);
        var topLevel = new List<string>();
        for (int i = 0; i < files.Count; i++)
        {
            var file = files[i];
            string relative = SafeRelativePath(file.Name);
            string path = Path.Combine(folder, relative);
            try
            {
                if (file.IsFolder)
                {
                    Directory.CreateDirectory(path);
                }
                else
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    if (!relative.Contains('\\')) path = Unused(path);
                    var clock = Stopwatch.StartNew();
                    var (bytes, medium) = SaveContents(data, i, file, path);
                    Log.Write($"  Saved {relative}: {bytes:N0} bytes, from {medium}, in {clock.ElapsedMilliseconds} ms");
                }
            }
            catch (Exception e)
            {
                Log.Write($"  Couldn't save {relative}: {e.Message}");
                continue;
            }
            string top = relative.Contains('\\') ? Path.Combine(folder, relative.Split('\\')[0]) : path;
            if (!topLevel.Contains(top)) topLevel.Add(top);
        }
        return topLevel;
    }

    static (long Bytes, string Medium) SaveContents(IDataObject data, int index, VirtualFile file, string path)
    {
        // Ask for any of the three ways a source can hand over a file's bytes. Some
        // sources are fussy about the request, so fall back to asking for one at a time.
        TYMED[] requests = [TYMED.TYMED_ISTREAM | TYMED.TYMED_HGLOBAL | TYMED.TYMED_ISTORAGE, TYMED.TYMED_ISTREAM, TYMED.TYMED_HGLOBAL, TYMED.TYMED_ISTORAGE];
        STGMEDIUM medium = default;
        Exception? lastError = null;
        bool got = false;
        foreach (var media in requests)
        {
            var request = Format(Formats.FileContents, media, index);
            try { data.GetData(ref request, out medium); got = true; break; }
            catch (Exception e) { lastError = e; }
        }
        if (!got) throw lastError ?? new InvalidOperationException("no contents");

        try
        {
            switch (medium.tymed)
            {
                case TYMED.TYMED_ISTREAM:
                {
                    var stream = (IStream)Marshal.GetObjectForIUnknown(medium.unionmember);
                    try { return (CopyStream(stream, path), "a stream"); }
                    finally { Marshal.ReleaseComObject(stream); }
                }
                case TYMED.TYMED_HGLOBAL:
                    return (CopyMemory(medium.unionmember, file.Size, path), "memory");
                case TYMED.TYMED_ISTORAGE:
                {
                    var storage = (IStorage)Marshal.GetObjectForIUnknown(medium.unionmember);
                    try { return (CopyStorage(storage, path), "a storage (Outlook item)"); }
                    finally { Marshal.ReleaseComObject(storage); }
                }
                default:
                    throw new InvalidOperationException($"unexpected medium {medium.tymed}");
            }
        }
        finally
        {
            ReleaseStgMedium(ref medium);
        }
    }

    static long CopyStream(IStream stream, string path)
    {
        try { stream.Seek(0, 0 /* STREAM_SEEK_SET */, IntPtr.Zero); } catch { /* not every stream can seek */ }
        var buffer = new byte[1 << 16];
        IntPtr readCount = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            using var output = File.Create(path);
            long total = 0;
            while (true)
            {
                stream.Read(buffer, buffer.Length, readCount);
                int read = Marshal.ReadInt32(readCount);
                if (read <= 0) break;
                output.Write(buffer, 0, read);
                total += read;
            }
            return total;
        }
        finally
        {
            Marshal.FreeHGlobal(readCount);
        }
    }

    static long CopyMemory(IntPtr memory, long? size, string path)
    {
        long available = (long)GlobalSize(memory);
        long length = size is long s && s <= available ? s : available;
        IntPtr pointer = GlobalLock(memory);
        try
        {
            using var output = File.Create(path);
            var buffer = new byte[1 << 16];
            for (long offset = 0; offset < length; offset += buffer.Length)
            {
                int chunk = (int)Math.Min(buffer.Length, length - offset);
                Marshal.Copy(pointer + (nint)offset, buffer, 0, chunk);
                output.Write(buffer, 0, chunk);
            }
            return length;
        }
        finally
        {
            GlobalUnlock(memory);
        }
    }

    static long CopyStorage(IStorage source, string path)
    {
        Marshal.ThrowExceptionForHR(StgCreateDocfile(path, STGM_CREATE | STGM_READWRITE | STGM_SHARE_EXCLUSIVE, 0, out var destination));
        try
        {
            source.CopyTo(0, IntPtr.Zero, IntPtr.Zero, destination);
            destination.Commit(0);
        }
        finally
        {
            Marshal.ReleaseComObject(destination); // closes the file
        }
        return new FileInfo(path).Length;
    }

    /// A virtual file's name, made safe to use under our folder: no drive letters, no
    /// "..", no characters Windows doesn't allow in names.
    static string SafeRelativePath(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var parts = name.Split('\\', '/')
            .Where(p => p.Length > 0 && p != "." && p != "..")
            .Select(p => new string(p.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).TrimEnd('.', ' '))
            .Where(p => p.Length > 0)
            .ToArray();
        return parts.Length == 0 ? "Untitled" : string.Join('\\', parts);
    }

    /// "photo.png", or "photo (2).png" if that's taken.
    static string Unused(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        string folder = Path.GetDirectoryName(path)!, name = Path.GetFileNameWithoutExtension(path), extension = Path.GetExtension(path);
        for (int n = 2; ; n++)
        {
            string candidate = Path.Combine(folder, $"{name} ({n}){extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
    }

    // ------------------------------------------------------------------ Writing into a data object

    /// Hands a block of memory to a data object, which then owns (and frees) it.
    public static void SetMemory(IDataObject data, short format, IntPtr memory)
    {
        var request = Format(format, TYMED.TYMED_HGLOBAL);
        var medium = new STGMEDIUM { tymed = TYMED.TYMED_HGLOBAL, unionmember = memory, pUnkForRelease = null };
        try { data.SetData(ref request, ref medium, true); }
        catch { GlobalFree(memory); throw; }
    }

    public static IntPtr Memory(byte[] bytes)
    {
        IntPtr memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, (UIntPtr)bytes.Length);
        Marshal.Copy(bytes, 0, GlobalLock(memory), bytes.Length);
        GlobalUnlock(memory);
        return memory;
    }

    public static IntPtr Memory(int value) => Memory(BitConverter.GetBytes(value));

    /// A DWORD-sized format such as Performed DropEffect, or null if it isn't there.
    public static int? ReadInt(IDataObject data, short format)
    {
        if (!Has(data, format, TYMED.TYMED_HGLOBAL)) return null;
        try
        {
            var request = Format(format, TYMED.TYMED_HGLOBAL);
            data.GetData(ref request, out var medium);
            try
            {
                int value = Marshal.ReadInt32(GlobalLock(medium.unionmember));
                GlobalUnlock(medium.unionmember);
                return value;
            }
            finally { ReleaseStgMedium(ref medium); }
        }
        catch { return null; }
    }

    /// Sets the label Windows shows under the dragged item's picture, such as
    /// "Add to Stow Lab". `%1` in the message is replaced by `insert`. Only sources
    /// that use the shell's drag pictures (File Explorer, most apps) show it; others
    /// ignore it, and some refuse the write, which is fine.
    public static void TrySetDropDescription(IDataObject data, int image, string message, string insert)
    {
        // DROPDESCRIPTION: an int, then two 260-character strings.
        var bytes = new byte[4 + 520 + 520];
        BitConverter.GetBytes(image).CopyTo(bytes, 0);
        Encoding.Unicode.GetBytes(message[..Math.Min(message.Length, 259)]).CopyTo(bytes, 4);
        Encoding.Unicode.GetBytes(insert[..Math.Min(insert.Length, 259)]).CopyTo(bytes, 524);
        try { SetMemory(data, Formats.DropDescription, Memory(bytes)); }
        catch { /* the source doesn't take drop descriptions */ }
    }
}
