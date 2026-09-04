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

The Windows app works end to end. The macOS half has not been started.

| | |
|---|---|
| Discovery (ports, PIDs, folders, page titles) | ✅ Windows |
| Contested-port detection | ✅ Windows |
| Tray panel, resident, close-to-tray | ✅ Windows |
| Start / stop (whole process tree) | ✅ Windows |
| Drop a folder to serve it | ✅ Windows |
| Built-in static server, no tooling needed | ✅ Windows |
| Auto-restart watchdog with backoff | ✅ Windows |
| Adopt an externally started server | ✅ Windows |
| Origin split (Mine / System) with manual pins | ✅ Windows |
| About/settings panel, Explorer "Start server here" verb | ✅ Windows |
| Packaging (`build/package.ps1` → zip + sha256) | ✅ Windows |
| Launch-at-login | not yet |
| Automated tests | not yet — `tests/` is a placeholder |
| macOS app | not started |

## Run it

```
dotnet build src/Serverlife/Serverlife.csproj
src/Serverlife/bin/Debug/net8.0-windows/Serverlife.exe
```

It lands in the notification area. Left-click toggles the panel; closing the window hides
it; Quit is on the tray menu. Pass a folder path to stage it for serving, which is what
the Explorer folder verb will do.

### Headless modes

```
Serverlife.exe --scan [--all]
Serverlife.exe --run <folder> [command] [--seconds N] [--no-restart]
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
tests/              placeholder — nothing here yet
build/              packaging scripts, one per platform (package.ps1 for Windows so far)
```

## Building a release

```
build\package.ps1
```

Publishes framework-dependent (needs the .NET 8 Desktop Runtime, not bundled), bundles
`LICENSE` and `THIRD-PARTY-NOTICES.md`, writes a `READ-ME-FIRST.txt`, and zips the result
with a `.sha256` beside it — into `dist/`, not committed.

## Licence

MIT. Bundles Fira Sans Condensed under the SIL Open Font License — see `licenses/` and
`THIRD-PARTY-NOTICES.md`.
