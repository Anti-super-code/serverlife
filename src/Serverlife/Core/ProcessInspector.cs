using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;

namespace Serverlife.Core;

/// <param name="CommandLine">Full argv as one string, or null if WMI would not say.</param>
/// <param name="WorkingDirectory">
/// The directory the process was launched from. This is what makes an externally
/// started server restartable, and it is the least reliable field here — see
/// <see cref="ProcessInspector.ReadWorkingDirectory"/>.
/// </param>
public sealed record ProcessDetails(
    int Pid,
    string Name,
    string? ExecutablePath,
    string? CommandLine,
    string? WorkingDirectory,
    int ParentPid);

/// <summary>
/// Describes the processes behind listening ports. Two different mechanisms, because
/// Windows exposes these facts in two different places:
///
///   * name / exe path / command line / parent — WMI's Win32_Process, one batched query.
///   * working directory — NOT exposed by WMI at all, so it is read out of the target's
///     PEB. That read is the fragile part and is allowed to fail quietly.
/// </summary>
public static class ProcessInspector
{
    /// <summary>
    /// Describes every requested pid in one WMI round trip. Unknown or exited pids are
    /// simply absent from the result rather than throwing.
    /// </summary>
    public static Dictionary<int, ProcessDetails> Describe(IReadOnlyCollection<int> pids)
    {
        var result = new Dictionary<int, ProcessDetails>();
        if (pids.Count == 0)
            return result;

        // One query for the whole batch: a per-pid WMI call costs tens of milliseconds
        // and this runs on a 2-second poll.
        var filter = string.Join(" OR ", pids.Select(p => $"ProcessId={p}"));
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, Name, ExecutablePath, CommandLine, ParentProcessId " +
                $"FROM Win32_Process WHERE {filter}");
            foreach (var o in searcher.Get())
            {
                using var mo = (ManagementObject)o;
                var pid = Convert.ToInt32(mo["ProcessId"]);
                result[pid] = new ProcessDetails(
                    Pid: pid,
                    Name: (mo["Name"] as string) ?? "unknown",
                    ExecutablePath: mo["ExecutablePath"] as string,
                    CommandLine: mo["CommandLine"] as string,
                    WorkingDirectory: ReadWorkingDirectory(pid),
                    ParentPid: mo["ParentProcessId"] is null ? 0 : Convert.ToInt32(mo["ParentProcessId"]));
            }
        }
        catch (ManagementException)
        {
            // WMI can be unavailable or throttled. Fall through to the cheap path so we
            // still show something useful for every pid.
        }

        foreach (var pid in pids)
        {
            if (result.ContainsKey(pid))
                continue;
            try
            {
                using var p = Process.GetProcessById(pid);
                result[pid] = new ProcessDetails(pid, p.ProcessName, null, null, ReadWorkingDirectory(pid), 0);
            }
            catch (ArgumentException)
            {
                // Exited between the port scan and here; leave it out.
            }
        }

        return result;
    }

    // ---- working directory, via the target process's PEB -------------------------
    //
    // Win32_Process has no CurrentDirectory property and there is no supported API for
    // reading another process's cwd, so this walks:
    //
    //     PEB -> ProcessParameters -> CurrentDirectory.DosPath (a UNICODE_STRING)
    //
    // Offsets below are for a 64-bit target on 64-bit Windows, which is the only case
    // handled: a 32-bit target has a separate WOW64 PEB with a different layout, and
    // the dev servers this app cares about (node, python, dotnet, cargo) are 64-bit.
    // Every failure path returns null, and the caller degrades to inferring a folder
    // from the command line.

    private const int ProcessBasicInformation = 0;

    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const int PROCESS_VM_READ = 0x0010;

    private const int PebOffsetProcessParameters = 0x20;
    private const int ParamsOffsetCurrentDirectory = 0x38;   // CURDIR.DosPath, a UNICODE_STRING
    private const int UnicodeStringOffsetBuffer = 0x08;      // Length(2) MaxLength(2) pad(4) Buffer(8)

    /// <summary>A UTF-16 path cannot exceed this many bytes; a longer read is garbage.</summary>
    private const int MaxPathBytes = 520;

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessBasicInformationData
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr handle, int infoClass, ref ProcessBasicInformationData info, int size, IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadProcessMemory(
        IntPtr handle, IntPtr address, byte[] buffer, int size, out IntPtr read);

    /// <summary>
    /// The launch directory of another process, or null when it cannot be read —
    /// a 32-bit target, a protected process, a race with exit, or a future Windows
    /// build moving these undocumented offsets. Callers must handle null.
    /// </summary>
    public static string? ReadWorkingDirectory(int pid)
    {
        if (!Environment.Is64BitProcess)
            return null;

        var handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, pid);
        if (handle == IntPtr.Zero)
            return null;

        try
        {
            var info = default(ProcessBasicInformationData);
            if (NtQueryInformationProcess(handle, ProcessBasicInformation, ref info, Marshal.SizeOf(info), IntPtr.Zero) != 0)
                return null;
            if (info.PebBaseAddress == IntPtr.Zero)
                return null;

            if (!TryReadPointer(handle, info.PebBaseAddress + PebOffsetProcessParameters, out var parameters))
                return null;

            var dosPath = parameters + ParamsOffsetCurrentDirectory;
            var lengthBytes = new byte[2];
            if (!ReadProcessMemory(handle, dosPath, lengthBytes, 2, out _))
                return null;

            var byteLength = BitConverter.ToUInt16(lengthBytes, 0);
            // A path is UTF-16, so an odd byte length means this is not the field we think.
            if (byteLength == 0 || byteLength % 2 != 0 || byteLength > MaxPathBytes)
                return null;

            if (!TryReadPointer(handle, dosPath + UnicodeStringOffsetBuffer, out var buffer))
                return null;

            var pathBytes = new byte[byteLength];
            if (!ReadProcessMemory(handle, buffer, pathBytes, byteLength, out _))
                return null;

            var path = Encoding.Unicode.GetString(pathBytes).Trim().TrimEnd('\\');
            return path.Length == 0 ? null : path;
        }
        catch (Exception)
        {
            // Undocumented layout: treat any surprise as "unknown", never as fatal.
            return null;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static bool TryReadPointer(IntPtr handle, IntPtr address, out IntPtr value)
    {
        var bytes = new byte[IntPtr.Size];
        if (!ReadProcessMemory(handle, address, bytes, bytes.Length, out _))
        {
            value = IntPtr.Zero;
            return false;
        }
        value = (IntPtr)BitConverter.ToInt64(bytes, 0);
        return value != IntPtr.Zero;
    }
}
