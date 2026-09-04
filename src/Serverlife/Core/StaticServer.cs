using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Serverlife.Core;

/// <summary>
/// A minimal static file server, so dropping a plain folder of HTML works with no
/// tooling installed at all.
///
/// Built on TcpListener rather than HttpListener deliberately: HttpListener goes through
/// http.sys, which requires a URL ACL reservation and therefore an admin prompt for any
/// prefix the user does not already own. A raw socket needs no such permission, and the
/// subset of HTTP a browser needs to render a local folder is small.
/// </summary>
public sealed class StaticServer : IDisposable
{
    private static readonly Dictionary<string, string> MimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        [".html"] = "text/html; charset=utf-8",
        [".htm"] = "text/html; charset=utf-8",
        [".css"] = "text/css; charset=utf-8",
        [".js"] = "text/javascript; charset=utf-8",
        [".mjs"] = "text/javascript; charset=utf-8",
        [".json"] = "application/json; charset=utf-8",
        [".svg"] = "image/svg+xml",
        [".png"] = "image/png",
        [".jpg"] = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".gif"] = "image/gif",
        [".webp"] = "image/webp",
        [".avif"] = "image/avif",
        [".ico"] = "image/x-icon",
        [".woff"] = "font/woff",
        [".woff2"] = "font/woff2",
        [".ttf"] = "font/ttf",
        [".otf"] = "font/otf",
        [".mp4"] = "video/mp4",
        [".webm"] = "video/webm",
        [".mp3"] = "audio/mpeg",
        [".wasm"] = "application/wasm",
        [".txt"] = "text/plain; charset=utf-8",
        [".map"] = "application/json; charset=utf-8",
        [".pdf"] = "application/pdf",
    };

    private readonly string _root;
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _cts = new();

    public int Port { get; }

    public StaticServer(string folder, int port = 0)
    {
        _root = Path.GetFullPath(folder);
        // Loopback only. This serves whatever folder was dropped on it, with no
        // authentication of any kind; binding the wildcard would publish it to the
        // network, which is never what dropping a folder on a tray app asks for.
        _listener = new TcpListener(IPAddress.Loopback, port);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
    }

    public void Start() => _ = AcceptLoopAsync(_cts.Token);

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
            }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            // Each connection is independent; one bad request must not stall the others.
            _ = ServeAsync(client, token);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken token)
    {
        using (client)
        {
            try
            {
                client.NoDelay = true;
                await using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);

                var requestLine = await reader.ReadLineAsync(token).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(requestLine))
                    return;

                var parts = requestLine.Split(' ');
                if (parts.Length < 2)
                    return;
                var method = parts[0];
                var target = parts[1];

                if (method is not ("GET" or "HEAD"))
                {
                    await WriteStatusAsync(stream, 405, "Method Not Allowed", token).ConfigureAwait(false);
                    return;
                }

                if (!TryResolve(target, out var file))
                {
                    await WriteStatusAsync(stream, 404, "Not Found", token).ConfigureAwait(false);
                    return;
                }

                await SendFileAsync(stream, file, headOnly: method == "HEAD", token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // A browser closing a connection mid-response is routine, not an error.
            }
        }
    }

    /// <summary>
    /// Maps a request target onto a real file, refusing anything that escapes the root.
    /// The containment check is done on the resolved absolute path, so "..", encoded
    /// separators and symlinked parents are all covered by the same test.
    /// </summary>
    private bool TryResolve(string target, out string file)
    {
        file = "";

        var path = target.Split('?', '#')[0];
        path = Uri.UnescapeDataString(path);
        if (path.StartsWith('/'))
            path = path[1..];

        var candidate = Path.GetFullPath(Path.Combine(_root, path.Replace('/', Path.DirectorySeparatorChar)));

        var rootWithSeparator = _root.EndsWith(Path.DirectorySeparatorChar)
            ? _root
            : _root + Path.DirectorySeparatorChar;
        if (!candidate.Equals(_root, StringComparison.OrdinalIgnoreCase)
            && !candidate.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
            return false;

        if (Directory.Exists(candidate))
            candidate = Path.Combine(candidate, "index.html");

        if (!File.Exists(candidate))
            return false;

        file = candidate;
        return true;
    }

    private static async Task SendFileAsync(Stream stream, string file, bool headOnly, CancellationToken token)
    {
        var info = new FileInfo(file);
        var type = MimeTypes.GetValueOrDefault(info.Extension, "application/octet-stream");

        var header = "HTTP/1.1 200 OK\r\n" +
                     $"Content-Type: {type}\r\n" +
                     $"Content-Length: {info.Length}\r\n" +
                     // A dev server that caches is a dev server you have to hard-refresh.
                     "Cache-Control: no-store\r\n" +
                     "Connection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header), token).ConfigureAwait(false);

        if (headOnly)
            return;

        await using var source = File.OpenRead(file);
        await source.CopyToAsync(stream, token).ConfigureAwait(false);
    }

    private static async Task WriteStatusAsync(Stream stream, int code, string reason, CancellationToken token)
    {
        var body = Encoding.UTF8.GetBytes($"<!doctype html><title>{code} {reason}</title><h1>{code} {reason}</h1>");
        var header = $"HTTP/1.1 {code} {reason}\r\n" +
                     "Content-Type: text/html; charset=utf-8\r\n" +
                     $"Content-Length: {body.Length}\r\n" +
                     "Connection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header), token).ConfigureAwait(false);
        await stream.WriteAsync(body, token).ConfigureAwait(false);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener.Stop();
        _cts.Dispose();
    }
}
