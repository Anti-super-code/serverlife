using System.IO;
using System.IO.Pipes;
using System.Text;

namespace Serverlife.Core;

/// <summary>
/// Serverlife is a resident tray app, but the "Start server here" Explorer verb launches
/// a brand new process every time it's used. Without this, that would mean a second tray
/// icon and a second discovery loop each time. The first process to grab the mutex stays
/// primary and runs a named-pipe server; every later launch hands its folder path over the
/// pipe, wakes the primary's window, and exits.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\Serverlife.Singleton";
    private const string PipeName = "Serverlife.Pipe";

    private Mutex? _mutex;

    public bool TryBecomePrimary()
    {
        try
        {
            _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
            if (createdNew)
                return true;
            try
            {
                if (_mutex.WaitOne(0))
                    return true; // previous primary exited between our ctor and here
            }
            catch (AbandonedMutexException)
            {
                return true; // previous primary crashed; we own the mutex now
            }
            return false;
        }
        catch
        {
            return true; // mutex machinery failing should never block the app
        }
    }

    /// <summary>Primary side: accepts folder paths (or an empty "just show yourself" ping) until cancelled.</summary>
    public async Task RunServerAsync(Action<string?> onFolderReceived, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = new NamedPipeServerStream(PipeName, PipeDirection.In,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(ct);
                using var reader = new StreamReader(server, Encoding.UTF8);
                var payload = (await reader.ReadToEndAsync(ct)).Trim();
                onFolderReceived(payload.Length == 0 ? null : payload);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                // A single broken client connection shouldn't kill the accept loop.
            }
            finally
            {
                server?.Dispose();
            }
        }
    }

    /// <summary>Secondary side: hands its folder (if any) to the primary. Retries while the primary's pipe comes up.</summary>
    public static bool TrySendToPrimary(string? folder, int timeoutMs = 3000)
    {
        var payload = Encoding.UTF8.GetBytes(folder ?? "");
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
                client.Connect(200);
                client.Write(payload);
                client.Flush();
                return true;
            }
            catch (TimeoutException)
            {
                Thread.Sleep(50);
            }
            catch (IOException)
            {
                Thread.Sleep(50);
            }
        }
        return false;
    }

    public void Dispose()
    {
        try
        {
            _mutex?.ReleaseMutex();
        }
        catch { /* not owned */ }
        _mutex?.Dispose();
    }
}
