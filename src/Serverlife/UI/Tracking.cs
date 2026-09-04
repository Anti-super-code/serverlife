using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace Serverlife.UI;

/// <summary>
/// WPF has no letter-spacing property, so this rebuilds a TextBlock's runs with a
/// scaled space between each character. <c>Em</c> is tracking expressed in ems,
/// matching the CSS <c>letter-spacing</c> values used across the Wind Router UI.
/// Setting <c>EmEnd</c> as well ramps the tracking linearly from the first gap to
/// the last, so a word can start airy and tighten toward its final letter.
/// </summary>
public static class Tracking
{
    /// <summary>A space glyph is roughly a quarter of an em, so the spacer is scaled against that.</summary>
    private const double SpaceGlyphEm = 0.25;

    public static readonly DependencyProperty EmProperty = DependencyProperty.RegisterAttached(
        "Em", typeof(double), typeof(Tracking), new PropertyMetadata(0.0, OnTrackingChanged));

    /// <summary>Tracking for the final gap. Leave unset to space every gap equally.</summary>
    public static readonly DependencyProperty EmEndProperty = DependencyProperty.RegisterAttached(
        "EmEnd", typeof(double), typeof(Tracking), new PropertyMetadata(double.NaN, OnTrackingChanged));

    /// <summary>The untracked text, kept so repeated applies don't compound the spacers.</summary>
    private static readonly DependencyProperty SourceTextProperty = DependencyProperty.RegisterAttached(
        "SourceText", typeof(string), typeof(Tracking), new PropertyMetadata(null));

    public static void SetEm(DependencyObject element, double value) => element.SetValue(EmProperty, value);

    public static double GetEm(DependencyObject element) => (double)element.GetValue(EmProperty);

    public static void SetEmEnd(DependencyObject element, double value) => element.SetValue(EmEndProperty, value);

    public static double GetEmEnd(DependencyObject element) => (double)element.GetValue(EmEndProperty);

    private static void OnTrackingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not TextBlock text)
            return;

        // Wait for load so both Text and the inherited FontSize are settled.
        if (text.IsLoaded)
            Apply(text);
        else
            text.Loaded += OnLoaded;
    }

    private static void OnLoaded(object sender, RoutedEventArgs e)
    {
        var text = (TextBlock)sender;
        text.Loaded -= OnLoaded;
        Apply(text);
    }

    /// <summary>
    /// Sets the text and re-applies tracking. Assigning <c>Text</c> directly would
    /// wipe the spaced runs, so tracked labels that change at runtime go through here.
    /// </summary>
    public static void SetText(TextBlock target, string value)
    {
        target.SetValue(SourceTextProperty, value);
        target.Text = value;
        Apply(target);
    }

    private static void Apply(TextBlock text)
    {
        var startEm = GetEm(text);
        if (startEm <= 0)
            return;

        if (text.GetValue(SourceTextProperty) is not string source)
        {
            source = text.Text;
            text.SetValue(SourceTextProperty, source);
        }
        if (string.IsNullOrEmpty(source))
            return;

        var endEm = GetEmEnd(text);
        if (double.IsNaN(endEm))
            endEm = startEm;

        var gaps = source.Length - 1;
        text.Inlines.Clear();
        for (var i = 0; i < source.Length; i++)
        {
            text.Inlines.Add(new Run(source[i].ToString()));
            if (i >= gaps)
                continue;

            var ramp = gaps > 1 ? (double)i / (gaps - 1) : 0.0;
            var em = startEm + (endEm - startEm) * ramp;
            if (em <= 0)
                continue;

            text.Inlines.Add(new Run(" ") { FontSize = Math.Max(0.1, text.FontSize * em / SpaceGlyphEm) });
        }
    }
}
