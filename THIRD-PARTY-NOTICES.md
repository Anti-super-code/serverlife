# Third-party notices

Serverlife itself is MIT-licensed (see `LICENSE`). It ships with the components below, each
under its own licence. The verbatim licence text for the font is in the `licenses/` folder
next to this file; the summaries here are for orientation and the full texts govern.

## Components

| Component | Version | Licence | Verbatim text |
|---|---|---|---|
| CommunityToolkit.Mvvm | 8.4.2 | MIT | https://github.com/CommunityToolkit/dotnet |
| System.Management | 8.0.0 | MIT | https://github.com/dotnet/runtime |
| Fira Sans Condensed | — | SIL Open Font License 1.1 | `licenses/fira-sans-condensed-OFL.txt` |
| .NET 8 Desktop Runtime | 8.x | MIT | https://github.com/dotnet/runtime |

No component here is copyleft — nothing to relink, no corresponding-source obligation, no
patent note. Serverlife makes no network connections of its own at all: discovery is local
process and port inspection, and the only outbound requests are the probes it makes to
`localhost` itself to read a served page's `<title>`.
