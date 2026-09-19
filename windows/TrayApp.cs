using System.Drawing;
using System.Media;

namespace Dictator;

/// <summary>
/// The whole app: a background system-tray agent with no main window (the WinForms
/// analog of the macOS MenuBarExtra in DictatorApp.swift). Hold the hotkey, talk,
/// release; the transcript lands where the cursor is.
///
/// Flow, mirroring the Mac AppDelegate:
///   Press   -> start mic capture, warm the backend connection, cue.
///   Release -> stop capture, WAV-encode, POST /v1/dictate, reconcile, inject text.
///   Cancel  -> a too-short tap: discard, no transcription.
/// </summary>
public sealed class TrayApp : ApplicationContext
{
    private readonly Settings _settings;
    private readonly Backend _backend;
    private readonly AudioRecorder _recorder = new();
    private readonly HotkeyHook _hook;
    private readonly NotifyIcon _tray;

    // A handle-owning control so background hook callbacks can marshal UI updates
    // (tray icon/tooltip/balloons) back to the UI thread. NotifyIcon is a Component,
    // not a Control, so it gives us no Invoke of its own.
    private readonly Control _uiSync;

    private readonly Icon _iconIdle;
    private readonly Icon _iconRecording;

    private volatile bool _recording;

    // ~1600 samples * 2 bytes/sample. Below this there is effectively nothing to send
    // (matches the Swift guard `trimmed.count > 1_600`).
    private const int MinPcmBytes = 1600 * 2;

    public TrayApp()
    {
        _settings = Settings.Load();
        _backend = new Backend(_settings.DeviceId);

        _uiSync = new Control();
        _ = _uiSync.Handle; // force handle creation on the UI thread now

        _iconIdle = MakeDotIcon(Color.FromArgb(120, 120, 120));
        _iconRecording = MakeDotIcon(Color.FromArgb(220, 60, 60));

        _tray = new NotifyIcon
        {
            Icon = _iconIdle,
            Visible = true,
            Text = "Dictator — ready",
            ContextMenuStrip = BuildMenu(),
        };

        _hook = new HotkeyHook(_settings.HotkeyVk);
        _hook.Press += OnPress;
        _hook.Release += OnRelease;
        _hook.Cancel += OnCancel;

        try
        {
            _hook.Start();
            SetTooltip($"Dictator — hold {KeyName(_settings.HotkeyVk)} to talk");
        }
        catch (Exception e)
        {
            SetTooltip("Dictator — hotkey failed");
            _tray.ShowBalloonTip(5000, "Dictator", $"Could not install the hotkey: {e.Message}", ToolTipIcon.Error);
        }
    }

    // MARK: - Menu

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();

        var modeMenu = new ToolStripMenuItem("Mode");
        foreach (DictationMode mode in Enum.GetValues<DictationMode>())
        {
            var item = new ToolStripMenuItem(mode.DisplayName())
            {
                CheckOnClick = false,
                Checked = mode == _settings.Mode,
                Tag = mode,
            };
            item.Click += (_, _) =>
            {
                _settings.Mode = mode;
                _settings.Save();
                foreach (ToolStripMenuItem sib in modeMenu.DropDownItems)
                    sib.Checked = (DictationMode)sib.Tag! == mode;
            };
            modeMenu.DropDownItems.Add(item);
        }
        menu.Items.Add(modeMenu);

        var sounds = new ToolStripMenuItem("Play start/stop sounds")
        {
            Checked = _settings.PlaySounds,
            CheckOnClick = true,
        };
        sounds.CheckedChanged += (_, _) =>
        {
            _settings.PlaySounds = sounds.Checked;
            _settings.Save();
        };
        menu.Items.Add(sounds);

        menu.Items.Add(new ToolStripSeparator());
        var about = new ToolStripMenuItem($"Hold {KeyName(_settings.HotkeyVk)} to talk") { Enabled = false };
        menu.Items.Add(about);
        menu.Items.Add(new ToolStripSeparator());

        var quit = new ToolStripMenuItem("Quit Dictator");
        quit.Click += (_, _) => ExitThread();
        menu.Items.Add(quit);

        return menu;
    }

    // MARK: - Dictation lifecycle (hook callbacks run on the thread pool)

    private void OnPress()
    {
        if (_recording) return;
        try
        {
            _recorder.Start();
            _recording = true;
            _backend.WarmConnection();
            PlayStart();
            OnUi(() =>
            {
                _tray.Icon = _iconRecording;
                SetTooltip("Dictator — listening…");
            });
        }
        catch (Exception e)
        {
            _recording = false;
            OnUi(() =>
            {
                _tray.Icon = _iconIdle;
                SetTooltip("Dictator — mic error");
                _tray.ShowBalloonTip(4000, "Dictator", $"Microphone error: {e.Message}", ToolTipIcon.Error);
            });
        }
    }

    private async void OnRelease()
    {
        if (!_recording) return;
        _recording = false;
        PlayStop();
        OnUi(() => SetTooltip("Dictator — transcribing…"));

        try
        {
            var pcm = await _recorder.StopAsync();
            pcm = AudioUtil.TrimSilence(pcm);
            if (pcm.Length <= MinPcmBytes)
            {
                ResetIdle();
                return;
            }

            var wav = WavEncoder.Encode(pcm);
            var mode = _settings.Mode;
            var result = await _backend.DictateAsync(wav, mode.SystemPrompt());

            // Cleanup safety net: never let a bad server cleanup overwrite the words.
            var text = Cleaner.Reconcile(result.Raw, result.Cleaned, mode);
            if (!string.IsNullOrEmpty(text))
                TextInjector.Insert(text);

            ResetIdle();
        }
        catch (Exception e)
        {
            OnUi(() =>
            {
                _tray.Icon = _iconIdle;
                SetTooltip("Dictator — ready");
                _tray.ShowBalloonTip(4000, "Dictator", $"Dictation failed: {e.Message}", ToolTipIcon.Warning);
            });
        }
    }

    private void OnCancel()
    {
        if (!_recording) return;
        _recording = false;
        _recorder.Cancel();
        ResetIdle();
    }

    private void ResetIdle() => OnUi(() =>
    {
        _tray.Icon = _iconIdle;
        SetTooltip($"Dictator — hold {KeyName(_settings.HotkeyVk)} to talk");
    });

    // MARK: - Cues

    private void PlayStart()
    {
        if (_settings.PlaySounds) SystemSounds.Beep.Play();
    }

    private void PlayStop()
    {
        if (_settings.PlaySounds) SystemSounds.Asterisk.Play();
    }

    // MARK: - UI helpers

    private void OnUi(Action action)
    {
        if (_uiSync.IsDisposed) return;
        try
        {
            if (_uiSync.InvokeRequired) _uiSync.BeginInvoke(action);
            else action();
        }
        catch (ObjectDisposedException) { /* shutting down */ }
    }

    private void SetTooltip(string text)
    {
        // NotifyIcon.Text is capped at 63 characters.
        _tray.Text = text.Length <= 63 ? text : text[..63];
    }

    private static string KeyName(int vk) => vk switch
    {
        HotkeyHook.VK_RCONTROL => "Right Ctrl",
        HotkeyHook.VK_LCONTROL => "Left Ctrl",
        HotkeyHook.VK_RMENU => "Right Alt",
        HotkeyHook.VK_RSHIFT => "Right Shift",
        HotkeyHook.VK_F8 => "F8",
        HotkeyHook.VK_CAPITAL => "Caps Lock",
        _ => $"key 0x{vk:X2}",
    };

    /// <summary>Draw a small colored-dot tray icon at runtime (no .ico asset needed).</summary>
    private static Icon MakeDotIcon(Color color)
    {
        using var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var brush = new SolidBrush(color);
            g.FillEllipse(brush, 2, 2, 12, 12);
        }
        // GetHicon creates an HICON we own; wrap and clone into a managed Icon so we
        // can destroy the native handle immediately and avoid leaking it.
        IntPtr hicon = bmp.GetHicon();
        try
        {
            using var tmp = Icon.FromHandle(hicon);
            return (Icon)tmp.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(hicon);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hook.Dispose();
            _recorder.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            _iconIdle.Dispose();
            _iconRecording.Dispose();
            _uiSync.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal static class NativeMethods
{
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
