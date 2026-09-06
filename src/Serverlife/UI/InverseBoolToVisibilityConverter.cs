using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Serverlife.UI;

/// <summary>
/// <c>true</c> → Collapsed, <c>false</c> → Visible. The mirror of WPF's built-in
/// <see cref="BooleanToVisibilityConverter"/>, for showing an element only while a flag
/// is off — here, the row's static name label while it is not being renamed.
/// </summary>
public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        value is Visibility.Visible ? false : true;
}
