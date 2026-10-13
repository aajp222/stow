using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using static StowLab.Native;

namespace StowLab;

public enum ItemKind { File, Link, Text }

/// One thing on the Lab's shelf.
public sealed class ShelfItem
{
    public required ItemKind Kind { get; init; }
    public required string Name { get; init; }
    /// For files and folders: where it is. The shelf holds a reference, not a copy.
    public string? Path { get; init; }
    /// For links and text.
    public string? Text { get; init; }
    public ImageSource? Icon { get; init; }
    /// Saved from a virtual file into the Promised folder, rather than dropped by path.
    public bool Promised { get; init; }

    public static ShelfItem File(string path, bool promised) => new()
    {
        Kind = ItemKind.File,
        Path = path,
        Name = System.IO.Path.GetFileName(path.TrimEnd('\\')) is { Length: > 0 } name ? name : path,
        Icon = Icons.For(path),
        Promised = promised,
    };
}

static class Icons
{
    /// The icon File Explorer shows for a file or folder. (Phase 2 replaces this with
    /// real thumbnails.)
    public static ImageSource? For(string path)
    {
        var info = new SHFILEINFO();
        IntPtr result = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_ICON | SHGFI_LARGEICON);
        if (result == 0 || info.hIcon == 0) return null;
        try
        {
            var image = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            image.Freeze();
            return image;
        }
        finally
        {
            DestroyIcon(info.hIcon);
        }
    }
}
