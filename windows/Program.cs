namespace Dictator;

/// <summary>
/// Entry point. Dictator is a background tray agent: there is no startup window, just
/// a NotifyIcon and a global hotkey. The single-instance guard keeps two copies from
/// installing two keyboard hooks (which would fire every callback twice).
/// </summary>
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // One instance only. A second launch simply exits.
        using var mutex = new Mutex(initiallyOwned: true, "Dictator.SingleInstance", out bool isNew);
        if (!isNew) return;

        ApplicationConfiguration.Initialize(); // sets visual styles + text rendering (net8 WinForms)
        using var app = new TrayApp();
        Application.Run(app);
    }
}
