# Serverlife

See every local dev server, start and stop them, and keep them alive while you present.

A small resident app for the Windows notification area and the macOS menu bar. It lists
what is listening on localhost — with the port, the folder, and the actual `<title>` of
the page being served, so a row reads *"Astarte 3D — workbench"* rather than *"node.exe"*.
Drop a folder on it to serve that folder. And when a server falls over mid-presentation,
it brings it back.

A sibling to [Photokompressor](https://github.com/Anti-super-code/Photokompressor), built
the same way: twin native apps sharing one design system — C#/WPF on Windows, Swift/SwiftUI
on macOS.

## Status

Early. Discovery works on Windows and is verified against real servers; the tray UI,
supervisor and macOS half are in progress.

| | |
|---|---|
| Discovery (ports, PIDs, folders, page titles) | ✅ Windows |
| Contested-port detection | ✅ Windows |
| Start / stop / drop-to-serve | in progress |
| Auto-restart watchdog | in progress |
| macOS app | in progress |

## Try the Windows discovery now

```
dotnet build src/Serverlife/Serverlife.csproj
src/Serverlife/bin/Debug/net8.0-windows/Serverlife.exe --scan
```

```
PORT   PID     PROCESS      NAME / TITLE                  FOLDER
5178   20548   node.exe     Astarte 3D — workbench        C:\...\Astarte 3D
8765!  7428    python.exe   Christopher Brellis — ...     C:\...\antidot 2026\site
...
! = port 8765 has 5 unrelated processes bound to it; only the last one to bind is serving.
```

`--all` also lists ports that did not answer as HTTP.

That `!` is worth explaining, because it is the reason this app is useful. Windows lets
several processes bind the same TCP port unless a socket asks for `SO_EXCLUSIVEADDRUSE`,
so orphaned dev servers quietly pile up and only the last one to bind gets the
connections. That is what "I edited the file and nothing changed" usually is.

## How it finds things

Windows exposes these facts in three different places, so discovery uses three mechanisms:

| Fact | Source |
|---|---|
| Listening ports → owning PID | `GetExtendedTcpTable` (iphlpapi) |
| Process name, command line, parent | `Win32_Process` via WMI, one batched query |
| **Working directory** | read out of the target process's PEB — WMI does not expose it |
| Page title | one capped `GET` to the port, cached per (port, PID) |

The PEB read is the fragile one: it uses undocumented offsets, handles 64-bit targets
only, and is allowed to fail quietly. Everything degrades to "unknown folder" rather
than breaking the list.

## Layout

```
src/Serverlife/     Windows app — C# / WPF, net8.0-windows
macos/              macOS app — Swift / SwiftUI, SwiftPM
tests/              Windows unit tests
build/              packaging scripts, one per platform
```

## Licence

MIT. Bundles Fira Sans Condensed under the SIL Open Font License — see `licenses/`.
