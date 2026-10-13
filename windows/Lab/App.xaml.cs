using System.Windows;
using System.Windows.Threading;

namespace StowLab;

public partial class App : Application
{
    public App()
    {
        // RegisterDragDrop fails (with a misleading "out of memory") on a thread where
        // OLE hasn't been set up. WPF does set it up, but only once it needs it itself.
        Native.OleInitialize(IntPtr.Zero);
    }

    /// Logs anything that goes wrong instead of closing, so the log can still be copied.
    void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Write($"ERROR: {e.Exception}");
        e.Handled = true;
    }
}
