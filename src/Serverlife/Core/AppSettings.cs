namespace Serverlife.Core;

/// <summary>App-level preferences — take effect immediately when toggled, not tied to any batch of work.</summary>
public class AppSettings
{
    public bool AlwaysOnTop { get; set; } = false;

    public AppSettings Clone() => (AppSettings)MemberwiseClone();
}
