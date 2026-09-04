using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Serverlife.UI;

/// <summary>
/// Hosts a row of RadioButtons and slides one accent pill to whichever segment is
/// checked, rather than cross-fading a separate pill per segment. The slide
/// overshoots slightly and settles back, so switching feels sprung.
/// </summary>
[TemplatePart(Name = PillPart, Type = typeof(FrameworkElement))]
public class SegmentTrack : ContentControl
{
    private const string PillPart = "PART_Pill";
    private const string ClipPart = "PART_Clip";
    private const double TrackCornerRadius = 9;
    private static readonly Duration SlideDuration = new(TimeSpan.FromMilliseconds(380));

    private FrameworkElement? _pill;
    private FrameworkElement? _clipHost;
    private TranslateTransform? _slide;
    private readonly List<RadioButton> _segments = new();
    private bool _placed;

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();

        _pill = GetTemplateChild(PillPart) as FrameworkElement;
        _clipHost = GetTemplateChild(ClipPart) as FrameworkElement;
        if (_pill != null)
        {
            _slide = new TranslateTransform();
            _pill.RenderTransform = _slide;
            _pill.Opacity = 0;
        }

        Loaded += (_, _) => Attach();
        SizeChanged += (_, _) =>
        {
            ClipToTrack();
            Place(Current(), animate: false);
        };
        IsEnabledChanged += (_, _) => FadePill();
    }

    /// <summary>
    /// Keeps the pill's spring overshoot inside the track's rounded edge — without
    /// this it visibly escapes the control when the outermost segment is picked.
    /// </summary>
    private void ClipToTrack()
    {
        if (_clipHost == null || _clipHost.ActualWidth <= 0)
            return;

        _clipHost.Clip = new RectangleGeometry(
            new Rect(0, 0, _clipHost.ActualWidth, _clipHost.ActualHeight),
            TrackCornerRadius, TrackCornerRadius);
    }

    private void Attach()
    {
        _segments.Clear();
        Collect(this);
        foreach (var segment in _segments)
        {
            segment.Checked -= OnSegmentChecked;
            segment.Checked += OnSegmentChecked;
        }
        Place(Current(), animate: false);
    }

    private void Collect(DependencyObject parent)
    {
        var count = VisualTreeHelper.GetChildrenCount(parent);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is RadioButton radio)
                _segments.Add(radio);
            else
                Collect(child);
        }
    }

    private RadioButton? Current() => _segments.FirstOrDefault(s => s.IsChecked == true);

    private void OnSegmentChecked(object sender, RoutedEventArgs e) =>
        Place((RadioButton)sender, animate: _placed);

    private void Place(RadioButton? target, bool animate)
    {
        if (_pill == null || _slide == null || target == null)
            return;

        // Measure against the pill's own parent, not the control: the track's 1px
        // border offsets that container, and measuring from outside it nudges the
        // pill a pixel down and right.
        var reference = (Visual?)_clipHost ?? this;

        // Before the first arrange pass there's nothing to measure against; retry
        // once at Loaded priority rather than spinning.
        if (target.ActualWidth <= 0 || !target.IsDescendantOf(reference))
        {
            Dispatcher.BeginInvoke(
                new Action(() =>
                {
                    if (target.ActualWidth > 0 && target.IsDescendantOf(reference))
                        Place(target, animate: false);
                }),
                DispatcherPriority.Loaded);
            return;
        }

        var origin = target.TransformToAncestor(reference).Transform(new Point(0, 0));
        _pill.Width = target.ActualWidth;
        _pill.Height = target.ActualHeight;
        _slide.Y = origin.Y;
        _placed = true;
        FadePill();

        if (animate)
        {
            _slide.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(origin.X, SlideDuration)
            {
                EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.35 },
            });
        }
        else
        {
            _slide.BeginAnimation(TranslateTransform.XProperty, null);
            _slide.X = origin.X;
        }
    }

    /// <summary>The pill sits outside the segments, so it has to dim with the track itself.</summary>
    private void FadePill()
    {
        if (_pill != null)
            _pill.Opacity = !_placed ? 0 : IsEnabled ? 1 : 0.45;
    }
}
