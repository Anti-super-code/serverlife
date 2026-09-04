using System.Net;
using System.Runtime.InteropServices;

namespace Serverlife.Core;

/// <summary>A socket in the LISTEN state, with the process that owns it.</summary>
/// <param name="Port">Local TCP port.</param>
/// <param name="Pid">Owning process id.</param>
/// <param name="Address">Local bind address, as reported by the TCP table.</param>
public readonly record struct Listener(int Port, int Pid, IPAddress Address)
{
    /// <summary>
    /// True when the socket is reachable from this machine's browser: either bound to
    /// a loopback address or to the wildcard (0.0.0.0 / ::), which includes loopback.
    /// Servers bound only to a LAN address are still listed, just not assumed local.
    /// </summary>
    public bool IsLocallyReachable =>
        IPAddress.IsLoopback(Address) || Address.Equals(IPAddress.Any) || Address.Equals(IPAddress.IPv6Any);
}

/// <summary>
/// Enumerates listening TCP sockets and their owning PIDs via iphlpapi's
/// GetExtendedTcpTable. The BCL's IPGlobalProperties.GetActiveTcpListeners() returns
/// the same endpoints but drops the PID, which is the half we actually need — without
/// it we could show a port but never name, stop, or restart what is behind it.
/// </summary>
public static class PortScanner
{
    private const int AF_INET = 2;
    private const int AF_INET6 = 23;

    /// <summary>TCP_TABLE_OWNER_PID_LISTENER — listeners only, so no filtering by state afterwards.</summary>
    private const int TCP_TABLE_OWNER_PID_LISTENER = 3;

    private const uint NO_ERROR = 0;
    private const uint ERROR_INSUFFICIENT_BUFFER = 122;

    // Row layouts, read by offset rather than declared as structs: the IPv6 row mixes
    // fixed byte arrays with scope ids, and hand-reading the few fields we want is
    // less error-prone than getting a blittable layout exactly right.
    private const int V4RowSize = 24;   // state, localAddr, localPort, remoteAddr, remotePort, pid
    private const int V6RowSize = 56;   // localAddr[16], scope, localPort, remoteAddr[16], scope, remotePort, state, pid

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(
        IntPtr pTcpTable, ref int pdwSize, bool bOrder, int ulAf, int tableClass, int reserved);

    /// <summary>
    /// All listening sockets, IPv4 and IPv6. Never throws: a failure in either family
    /// yields that family's sockets as empty rather than taking down the poll loop.
    /// </summary>
    public static List<Listener> GetListeners()
    {
        var results = new List<Listener>();
        ReadTable(AF_INET, results);
        ReadTable(AF_INET6, results);
        return results;
    }

    private static void ReadTable(int family, List<Listener> into)
    {
        var size = 0;
        var status = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (status != ERROR_INSUFFICIENT_BUFFER && status != NO_ERROR)
            return;
        if (size <= 0)
            return;

        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            status = GetExtendedTcpTable(buffer, ref size, false, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (status != NO_ERROR)
                return;

            var count = Marshal.ReadInt32(buffer);
            var rowSize = family == AF_INET ? V4RowSize : V6RowSize;
            var addrLength = family == AF_INET ? 4 : 16;

            for (var i = 0; i < count; i++)
            {
                // The table's declared entry count is trusted only as far as the buffer
                // we were given actually reaches.
                var rowStart = 4 + (i * rowSize);
                if (rowStart + rowSize > size)
                    break;

                var row = buffer + rowStart;
                // IPv4 puts state first and the address second; IPv6 leads with the address.
                var addrOffset = family == AF_INET ? 4 : 0;
                var portOffset = family == AF_INET ? 8 : 20;
                var pidOffset = family == AF_INET ? 20 : 52;

                var addrBytes = new byte[addrLength];
                Marshal.Copy(row + addrOffset, addrBytes, 0, addrLength);

                into.Add(new Listener(
                    Port: ReadPort(row + portOffset),
                    Pid: Marshal.ReadInt32(row + pidOffset),
                    Address: new IPAddress(addrBytes)));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    /// <summary>
    /// The port occupies a 4-byte field but is a network-order u16 in the first two
    /// bytes; the remaining two are padding and must be ignored, not folded in.
    /// </summary>
    private static int ReadPort(IntPtr at)
    {
        var hi = Marshal.ReadByte(at);
        var lo = Marshal.ReadByte(at + 1);
        return (hi << 8) | lo;
    }
}
