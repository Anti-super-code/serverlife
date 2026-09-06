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

Both apps work end to end.

| | | |
|---|---|---|
| Discovery (ports, PIDs, folders, page titles) | ✅ Windows | ✅ macOS |
| Origin split (Mine / System) with manual pins | ✅ Windows | ✅ macOS |
| Contested-port detection | ✅ Windows | ✅ macOS, rare in practice |
| Tray / menu bar panel, resident, close-to-tray | ✅ Windows | ✅ macOS |
| About & settings panel, always-on-top | ✅ Windows | ✅ macOS |
| Start / stop (whole process tree) | ✅ Windows | ✅ macOS |
| Drop a folder to serve it | ✅ Windows | ✅ macOS |
| Built-in static server, no tooling needed | ✅ Windows | ✅ macOS |
| Auto-restart watchdog with backoff | ✅ Windows | ✅ macOS |
| Adopt an externally started server | ✅ Windows | ✅ macOS |
| Right-click "Start server here" | ✅ Windows (Explorer verb) | ✅ macOS (Finder Quick Action) |
| Single-instance folder handoff | ✅ Windows (mutex/pipe) | ✅ macOS (free — `LSMultipleInstancesProhibited`) |
| Packaging (sha256 beside every artifact) | ✅ Windows — portable zip **and** an installer (`build/package.ps1`) | ✅ macOS app (`build/package-mac.sh`) |
| Automated tests | not yet — `tests/` is a placeholder | ✅ macOS (`macos/Tests/ServerlifeCoreTests`) |
| Launch-at-login | not yet | not yet |
| CI / notarization | not yet | not yet |

## Run it

### Windows

```
dotnet build src/Serverlife/Serverlife.csproj
src/Serverlife/bin/Debug/net8.0-windows/Serverlife.exe
```

It lands in the notification area. Left-click toggles the panel; closing the window hides
it; Quit is on the tray menu. Pass a folder path to stage it for serving, which is what
the Explorer folder verb will do.

### macOS

```
cd macos && swift build
.build/debug/Serverlife
```

It lands in the menu bar (and the Dock). Left-click the menu bar icon toggles the panel;
closing it hides to the menu bar; Quit is on its right-click menu. Drag a folder onto it,
or right-click a folder in Finder and choose "Start server here" once that's switched on
from the (i) button's settings panel.

### Headless modes

Windows:

```
Serverlife.exe --scan [--all]
Serverlife.exe --run <folder> [command] [--seconds N] [--no-restart]
```

macOS (a separate `serverlife-cli` binary, built from `macos/Sources/ServerlifeCLI`):

```
serverlife-cli --scan [--all]
serverlife-cli --run <folder> [command] [--seconds N] [--no-restart]
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

Windows and macOS expose these facts in different places entirely, so each platform's
`Discovery` uses its own mechanisms:

| Fact | Windows | macOS |
|---|---|---|
| Listening ports → owning PID | `GetExtendedTcpTable` (iphlpapi) | `proc_listpids` → `proc_pidinfo`/`proc_pidfdinfo` (libproc) |
| Process name, command line, parent | `Win32_Process` via WMI, one batched query | `proc_name`, `sysctl(KERN_PROCARGS2)`, `proc_pidinfo` — one syscall each, no batching needed |
| **Working directory** | read out of the target process's PEB — WMI does not expose it | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — a documented API |
| Page title | one capped `GET` to the port, cached per (port, PID) | same |

On Windows the PEB read is the fragile step: undocumented offsets, 64-bit targets only,
allowed to fail quietly. macOS has no such step — `PROC_PIDVNODEPATHINFO` is a supported
API — so the only way a folder comes back unknown there is a same-uid restriction (a
process owned by another user). Both platforms degrade to "unknown folder" rather than
breaking the list.

Contested ports — several unrelated processes bound to the same port, which is what "I
edited the file and nothing changed" usually turns out to be — are a genuinely Windows
pathology: Windows allows a second bind unless a socket asks for `SO_EXCLUSIVEADDRUSE`,
while BSD (macOS) refuses a second bind outright unless a socket asks for the opposite,
`SO_REUSEPORT`. The detection ships on both platforms, but it is rare in practice on macOS.

## Layout

```
src/Serverlife/     Windows app — C# / WPF, net8.0-windows
macos/              macOS app — Swift / SwiftUI, SwiftPM
                      Sources/ServerlifeCore   discovery, supervisor, static server, Finder integration
                      Sources/ServerlifeCLI    headless --scan / --run, a separate binary
                      Sources/Serverlife       the menu bar app
                      Tests/ServerlifeCoreTests
tests/              placeholder — nothing here yet
build/              packaging scripts, one per platform (package.ps1, package-mac.sh)
                      installer/               Inno Setup script + generated wizard art
```

## Building a release

Windows:

```
build\package.ps1                  # both downloads
build\package.ps1 -SkipInstaller   # zip only, no Inno Setup needed
```

Publishes framework-dependent (needs the .NET 8 Desktop Runtime, not bundled) and produces
two things in `dist/`, not committed, each with a `.sha256` beside it:

- **`Serverlife-<version>-win-x64.zip`** — the published folder plus `LICENSE`,
  `THIRD-PARTY-NOTICES.md` and a `READ-ME-FIRST.txt`. Extract-and-run, for people who
  want no installer.
- **`Serverlife-Setup-<version>.exe`** — an [Inno Setup](https://jrsoftware.org/isinfo.php)
  installer (`build/installer/serverlife.iss`, modern wizard, art from
  `make-wizard-art.py`). Installs per-user to `%LOCALAPPDATA%\Programs\Serverlife` with no
  admin, Start-menu shortcut and an entry in Add/Remove Programs. It carries only the
  ~1 MB app: on a machine **without** the .NET 8 Desktop Runtime it downloads that from
  Microsoft during setup, and on one that already has it nothing extra is fetched. A
  checkbox (off by default) registers the "Start server here" Explorer verb by calling the
  app's own `--register-shell`; uninstall calls `--unregister-shell`.

The installer step needs Inno Setup 6 — `winget install JRSoftware.InnoSetup`. Without it,
`package.ps1` warns and builds just the zip.

macOS:

```
bash build/package-mac.sh
```

Builds both the app and `serverlife-cli`, assembles a self-contained, ad-hoc-signed
`Serverlife.app` with its own `.icns` and bundled fonts, and bundles `LICENSE` and a
`READ-ME-FIRST.txt` beside it — into `dist-mac/`, not committed.

## Licence

MIT. Bundles Fira Sans Condensed under the SIL Open Font License — see `licenses/` and
`THIRD-PARTY-NOTICES.md`.
