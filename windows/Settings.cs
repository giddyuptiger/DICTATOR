using System.Text.Json;
using System.Text.Json.Serialization;

namespace Dictator;

/// <summary>
/// Small JSON settings file under %APPDATA%\Dictator\settings.json. Holds the stable
/// per-install device id (mirrors Backend.deviceID in Backend.swift), the selected
/// dictation mode, and the hold-to-talk key. Kept deliberately tiny; a corrupt or
/// missing file just yields defaults.
/// </summary>
public sealed class Settings
{
    /// <summary>
    /// A stable per-install id so the backend can rate-limit per device (not just per
    /// IP). Not personally identifying — a random GUID created once, exactly like the
    /// Swift app's <c>Backend.deviceID</c>.
    /// </summary>
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("mode")]
    public DictationMode Mode { get; set; } = DictationMode.Casual;

    /// <summary>
    /// The virtual-key code of the hold-to-talk key. Default is Right Ctrl
    /// (VK_RCONTROL, 0xA3). See <see cref="HotkeyHook"/> for why a low-level hook.
    /// </summary>
    [JsonPropertyName("hotkeyVk")]
    public int HotkeyVk { get; set; } = HotkeyHook.VK_RCONTROL;

    [JsonPropertyName("playSounds")]
    public bool PlaySounds { get; set; } = true;

    [JsonIgnore]
    public static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Dictator");

    [JsonIgnore]
    private static string FilePath => Path.Combine(Directory, "settings.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        // Persist the DictationMode enum by name ("Casual"), not by ordinal, so the
        // file survives a reordering of the enum.
        Converters = { new JsonStringEnumConverter() },
    };

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                var loaded = JsonSerializer.Deserialize<Settings>(json, JsonOptions);
                if (loaded is not null)
                {
                    // A device id must always exist; backfill if an old file lacks one.
                    if (string.IsNullOrWhiteSpace(loaded.DeviceId))
                        loaded.DeviceId = Guid.NewGuid().ToString();
                    return loaded;
                }
            }
        }
        catch
        {
            // Corrupt file -> fall through to defaults. Never block startup on settings.
        }

        var fresh = new Settings();
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
        }
        catch
        {
            // Best effort; a failed save just means the choice is not remembered.
        }
    }
}
