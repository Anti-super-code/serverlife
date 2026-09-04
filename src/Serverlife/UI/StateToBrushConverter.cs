using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using Serverlife.ViewModels;

namespace Serverlife.UI;

/// <summary>
/// Maps a row's state onto the theme's existing semantic brushes rather than inventing
/// status colours: running is the same green the rest of the design system already calls
/// "Good", and so on down. Looking them up by key keeps the palette in exactly one place.
/// </summary>
public sealed class StateToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value switch
        {
            ServerState.Running => "Good",
            ServerState.Restarting => "Warn",
            ServerState.Failed => "Danger",
            _ => "TextLo",
        };
        return Application.Current?.TryFindResource(key) as Brush ?? Brushes.Gray;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
