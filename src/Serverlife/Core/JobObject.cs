using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Serverlife.Core;

/// <summary>
/// A Windows job object that kills everything inside it when disposed.
///
/// This is the whole reason stopping a server actually works. "npm run dev" is a batch
/// file that launches node, which launches the real dev server; killing the process we
/// spawned leaves the listener running and the port held. taskkill /T walks the tree by
/// parent id, which is already wrong by the time an intermediate process has exited and
/// orphaned its children. A job object is held by the kernel and covers every descendant
/// no matter who exited in between.
/// </summary>
public sealed class JobObject : IDisposable
{
    private IntPtr _handle;

    public JobObject()
    {
        _handle = CreateJobObject(IntPtr.Zero, null);
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException($"CreateJobObject failed: {Marshal.GetLastWin32Error()}");

        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            },
        };

        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(_handle, JobObjectExtendedLimitInformation, buffer, (uint)size))
                throw new InvalidOperationException(
                    $"SetInformationJobObject failed: {Marshal.GetLastWin32Error()}");
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    /// <summary>
    /// Puts a process, and by inheritance everything it goes on to spawn, under this job.
    /// Returns false rather than throwing if the process has already exited.
    /// </summary>
    public bool Assign(Process process)
    {
        try
        {
            return AssignProcessToJobObject(_handle, process.Handle);
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// Whether a pid belongs to this job. This is how a started server's port is found:
    /// "npm run dev" means the process holding the socket is usually a grandchild we
    /// never had a handle to, so rather than guessing at the tree we ask the kernel
    /// whether each listening process is one of ours.
    /// </summary>
    public bool Contains(int pid)
    {
        var process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero)
            return false;
        try
        {
            return IsProcessInJob(process, _handle, out var member) && member;
        }
        finally
        {
            CloseHandle(process);
        }
    }

    /// <summary>
    /// Kills every process in the job, immediately. Disposing would do the same via
    /// KILL_ON_JOB_CLOSE, but only once the last handle closes — being explicit means
    /// "Stop" is synchronous and the port is free when it returns.
    /// </summary>
    public void Kill()
    {
        if (_handle != IntPtr.Zero)
            TerminateJobObject(_handle, 0);
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero)
            return;
        CloseHandle(_handle);
        _handle = IntPtr.Zero;
    }

    // ---- interop ---------------------------------------------------------------

    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
}
