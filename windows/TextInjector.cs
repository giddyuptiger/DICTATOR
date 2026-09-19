using System.Runtime.InteropServices;

namespace Dictator;

/// <summary>
/// Types text into whatever window currently has focus, using SendInput with
/// KEYEVENTF_UNICODE. This is the Windows analog of MacTextInserter.swift.
///
/// WHY SendInput (Unicode) AND NOT THE CLIPBOARD:
///   The Mac app pastes because the AX insertion API is unreliable in Electron apps.
///   On Windows, SendInput with KEYEVENTF_UNICODE synthesizes real character input
///   that virtually every app (native, Win32, Electron/Chromium, UWP) accepts, and it
///   does NOT clobber the user's clipboard — so it is the cleaner default. Each UTF-16
///   code unit is sent as its own key-down/key-up pair; because we iterate the string
///   by char (UTF-16 code units), surrogate pairs (emoji) are sent as their two
///   surrogate units in order, which is exactly what Windows expects.
///
/// Limitation: SendInput cannot inject into a window owned by a higher-integrity
/// (elevated/admin) process while we run un-elevated. That is an accepted v1 limit.
/// </summary>
public static class TextInjector
{
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    public static void Insert(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        // Two INPUTs (down + up) per UTF-16 code unit.
        var inputs = new INPUT[text.Length * 2];
        int i = 0;

        foreach (char c in text)
        {
            inputs[i++] = MakeUnicode(c, keyUp: false);
            inputs[i++] = MakeUnicode(c, keyUp: true);
        }

        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
        {
            // Partial injection usually means input was blocked (e.g. a focused
            // elevated window, or UIPI). Nothing we can safely do here; surface via
            // Win32 last error for logging by the caller if desired.
            _ = Marshal.GetLastWin32Error();
        }
    }

    private static INPUT MakeUnicode(char code, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,               // must be 0 for a Unicode keystroke
                wScan = code,          // the UTF-16 code unit to type
                dwFlags = KEYEVENTF_UNICODE | (keyUp ? KEYEVENTF_KEYUP : 0),
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            },
        },
    };

    // MARK: - P/Invoke structs and imports

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    // A C union: mouse / keyboard / hardware overlap at offset 0. We only ever use ki.
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
}
