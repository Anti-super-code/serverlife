using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;

namespace Serverlife.Core;

/// <param name="IsHttp">False when the port answered but not as HTTP (a database, say).</param>
/// <param name="Title">The page's &lt;title&gt;, trimmed, or null if it had none.</param>
/// <param name="Scheme">"http" or "https" — whichever actually answered.</param>
public sealed record ProbeResult(bool IsHttp, string? Title, string? Scheme, HttpStatusCode? Status)
{
    public static readonly ProbeResult NotHttp = new(false, null, null, null);
}

/// <summary>
/// Asks a local port what it is serving, so a row can read "Vite + React" instead of
/// "node.exe". One GET per port, cached by the caller — see <see cref="Discovery"/>.
/// </summary>
public static partial class HttpProbe
{
    private static readonly TimeSpan Timeout = TimeSpan.FromMilliseconds(800);

    /// <summary>
    /// Ports that are never worth a probe. Sending even a well-formed GET to a database
    /// makes it log a protocol error, so they are skipped outright rather than tried
    /// and discarded.
    /// </summary>
    private static readonly HashSet<int> NeverProbe =
    [
        135,    // RPC endpoint mapper
        139,    // NetBIOS
        445,    // SMB
        1433,   // SQL Server
        3306,   // MySQL
        5432,   // PostgreSQL
        6379,   // Redis
        11211,  // memcached
        27017,  // MongoDB
    ];

    /// <summary>
    /// Shared across probes: a fresh HttpClient per call leaks sockets in TIME_WAIT,
    /// which on a 2-second poll adds up fast. Redirects stay off so the title we read
    /// belongs to the port we asked about, not to wherever it forwards.
    /// </summary>
    private static readonly HttpClient Client = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        // Dev servers self-sign as a matter of course; we are talking to loopback and
        // only reading a title, so certificate identity proves nothing worth enforcing.
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,
    })
    {
        Timeout = Timeout,
    };

    [GeneratedRegex(@"<title[^>]*>(.*?)</title>",
        RegexOptions.IgnoreCase | RegexOptions.Singleline, matchTimeoutMilliseconds: 500)]
    private static partial Regex TitlePattern();

    /// <summary>Collapses the runs of whitespace and newlines that titles are often formatted across.</summary>
    [GeneratedRegex(@"\s+", RegexOptions.None, matchTimeoutMilliseconds: 500)]
    private static partial Regex WhitespaceRun();

    public static bool ShouldProbe(int port) => !NeverProbe.Contains(port);

    /// <summary>
    /// Probes http first, then https. Never throws: an unreachable or non-HTTP port
    /// comes back as <see cref="ProbeResult.NotHttp"/>.
    /// </summary>
    public static async Task<ProbeResult> ProbeAsync(int port, CancellationToken token = default)
    {
        if (!ShouldProbe(port))
            return ProbeResult.NotHttp;

        var viaHttp = await TryOneAsync("http", port, token).ConfigureAwait(false);
        if (viaHttp.IsHttp)
            return viaHttp;

        return await TryOneAsync("https", port, token).ConfigureAwait(false);
    }

    private static async Task<ProbeResult> TryOneAsync(string scheme, int port, CancellationToken token)
    {
        try
        {
            using var response = await Client
                .GetAsync($"{scheme}://127.0.0.1:{port}/", HttpCompletionOption.ResponseHeadersRead, token)
                .ConfigureAwait(false);

            // A redirect or a 404 still proves something HTTP is listening, which is all
            // we need to call the port a web server; it just has no title to show.
            if (!IsHtml(response))
                return new ProbeResult(true, null, scheme, response.StatusCode);

            var html = await ReadCappedAsync(response, token).ConfigureAwait(false);
            return new ProbeResult(true, ExtractTitle(html), scheme, response.StatusCode);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException
                                       or InvalidOperationException or IOException)
        {
            // Connection refused, TLS mismatch, timeout, or a service that answered with
            // something that is not HTTP at all. All mean the same thing to us.
            return ProbeResult.NotHttp;
        }
    }

    private static bool IsHtml(HttpResponseMessage response)
    {
        var mediaType = response.Content.Headers.ContentType?.MediaType;
        // A dev server that omits Content-Type is still worth parsing; a JSON API is not.
        return mediaType is null || mediaType.Contains("html", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Reads only the head of the document. The title lives in &lt;head&gt;, and some dev
    /// servers stream responses that never end — reading to completion would hang until
    /// the timeout on every single poll.
    /// </summary>
    private static async Task<string> ReadCappedAsync(HttpResponseMessage response, CancellationToken token)
    {
        const int cap = 64 * 1024;
        await using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        var buffer = new byte[cap];
        var filled = 0;
        while (filled < cap)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(filled, cap - filled), token).ConfigureAwait(false);
            if (read == 0)
                break;
            filled += read;
        }
        return System.Text.Encoding.UTF8.GetString(buffer, 0, filled);
    }

    private static string? ExtractTitle(string html)
    {
        var match = TitlePattern().Match(html);
        if (!match.Success)
            return null;
        var title = WhitespaceRun().Replace(WebUtility.HtmlDecode(match.Groups[1].Value), " ").Trim();
        return title.Length == 0 ? null : title;
    }
}
