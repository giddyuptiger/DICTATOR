using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Dictator;

/// <summary>
/// Hold-to-talk on a single key, implemented with a low-level keyboard hook
/// (WH_KEYBOARD_LL via SetWindowsHookEx). This is the Windows analog of the macOS
/// CGEventTap in HotkeyMonitor.swift.
///
/// WHY A LOW-LEVEL HOOK AND NOT RegisterHotKey:
///   RegisterHotKey only signals a *press* (a WM_HOTKEY message) — it gives you no
///   key-up, so you cannot tell how long a key is held. Dictator is hold-to-talk:
///   we must start recording on key-down and stop on key-up. A low-level keyboard
///   hook sees both WM_KEYDOWN/WM_SYSKEYDOWN and WM_KEYUP/WM_SYSKEYUP for every key
///   system-wide, so it can drive begin()/end() the way the Mac's flagsChanged tap
///   does. It also lets us optionally swallow the key so the focused app never sees
///   the trigger.
///
/// The hook callback runs on the thread that installed the hook, which MUST have a
/// running message loop — so we install it from the WinForms UI thread (Application.Run
/// pumps messages). Keep the callback fast: Windows silently drops a hook whose
/// callback is too slow, so all real work (mic start/stop, network) is dispatched off
/// the callback via the Press/Release/Cancel events, whose handlers marshal to a
/// background task.
/// </summary>
public sealed class HotkeyHook : IDisposable
{
    // Common virtual-key codes for trigger selection. A low-level keyboard hook
    // reports the SPECIFIC left/right modifier vk (unlike a normal WndProc, which
    // collapses them to VK_CONTROL etc.), so VK_RCONTROL genuinely distinguishes the
    // right Ctrl from the left.
    public const int VK_RCONTROL = 0xA3; // right Ctrl (default trigger)
    public const int VK_LCONTROL = 0xA2;
    public const int VK_RMENU = 0xA5;    // right Alt
    public const int VK_RSHIFT = 0xA1;
    public const int VK_F8 = 0x77;
    public const int VK_CAPITAL = 0x14;  // Caps Lock

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104; // fires for keys pressed with Alt held
    private const int WM_SYSKEYUP = 0x0105;

    /// <summary>Fired on the first key-down of a hold (auto-repeat is suppressed).</summary>
    public event Action? Press;

    /// <summary>Fired on key-up when the key was held at least <see cref="MinimumHold"/>.</summary>
    public event Action? Release;

    /// <summary>
    /// Fired instead of <see cref="Release"/> when the key was tapped for less than
    /// <see cref="MinimumHold"/>. A brushed key should discard, not transcribe.
    /// </summary>
    public event Action? Cancel;

    /// <summary>Ignore holds shorter than this, so a stray tap does nothing.</summary>
    public TimeSpan MinimumHold { get; set; } = TimeSpan.FromMilliseconds(150);

    private readonly int _triggerVk;
    private readonly bool _swallow;

    // The delegate MUST be kept alive for the lifetime of the hook; if it is
    // collected, Windows calls into freed memory. Storing it in a field pins it.
    private readonly LowLevelKeyboardProc _proc;
    private IntPtr _hookId = IntPtr.Zero;

    private bool _isHeld;
    private long _pressedAtTicks;

    /// <param name="triggerVk">Virtual-key code of the hold-to-talk key.</param>
    /// <param name="swallow">
    /// When true, the trigger key's events are consumed so the focused app never sees
    /// them (matches the Mac, which swallows the modifier). Set false if you want the
    /// key to keep its normal function.
    /// </param>
    public HotkeyHook(int triggerVk = VK_RCONTROL, bool swallow = true)
    {
        _triggerVk = triggerVk;
        _swallow = swallow;
        _proc = HookCallback;
    }

    /// <summary>Install the hook. Throws <see cref="Win32Exception"/> on failure.</summary>
    public void Start()
    {
        if (_hookId != IntPtr.Zero) return;

        // A WH_KEYBOARD_LL hook is a global hook but, unlike most global hooks, it does
        // NOT need to live in a separate DLL and the module handle can be that of the
        // current process (or the main module). Passing GetModuleHandle(null) is the
        // idiomatic value here; dwThreadId 0 makes it system-wide.
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule!;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(curModule.ModuleName), 0);

        if (_hookId == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetWindowsHookEx (WH_KEYBOARD_LL) failed.");
    }

    public void Stop()
    {
        if (_hookId != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookId);
            _hookId = IntPtr.Zero;
        }
        _isHeld = false;
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        // nCode < 0 means "do not process, just pass along" per the hook contract.
        if (nCode < 0)
            return CallNextHookEx(_hookId, nCode, wParam, lParam);

        var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        int msg = (int)wParam;
        bool isOurKey = (int)data.vkCode == _triggerVk;

        if (isOurKey)
        {
            bool isDown = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
            bool isUp = msg is WM_KEYUP or WM_SYSKEYUP;

            if (isDown && !_isHeld)
            {
                _isHeld = true;
                _pressedAtTicks = Stopwatch.GetTimestamp();
                // Fire off the message loop / thread pool so the callback returns fast.
                var handler = Press;
                if (handler is not null) ThreadPool.QueueUserWorkItem(_ => handler());
            }
            else if (isUp && _isHeld)
            {
                _isHeld = false;
                var held = Stopwatch.GetElapsedTime(_pressedAtTicks);
                if (held >= MinimumHold)
                {
                    var handler = Release;
                    if (handler is not null) ThreadPool.QueueUserWorkItem(_ => handler());
                }
                else
                {
                    var handler = Cancel;
                    if (handler is not null) ThreadPool.QueueUserWorkItem(_ => handler());
                }
            }
            // isDown while already held == auto-repeat: ignore it entirely.

            if (_swallow && (isDown || isUp))
                return (IntPtr)1; // non-zero eats the event; the focused app never sees it.
        }

        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public void Dispose() => Stop();

    // MARK: - P/Invoke

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}

/// <summary>Thin wrapper so callers don't need to import System.ComponentModel directly.</summary>
public sealed class Win32Exception : Exception
{
    public int NativeErrorCode { get; }
    public Win32Exception(int code, string message) : base($"{message} (Win32 error {code})") => NativeErrorCode = code;
}
