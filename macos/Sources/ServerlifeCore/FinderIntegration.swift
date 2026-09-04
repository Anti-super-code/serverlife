import Foundation

/// macOS equivalent of ShellRegistration.cs. Windows adds an HKCU shell verb under both
/// `Directory\shell` and `Directory\Background\shell` (right-click a folder, or
/// right-click inside one); the closest macOS analogue is a Finder Quick Action, which
/// is an Automator .workflow bundle installed to ~/Library/Services (no admin needed,
/// same as the Windows HKCU-only approach). A Quick Action registered against
/// `public.folder` already covers both Finder contexts on its own, so there is no
/// separate "background" registration to add here.
///
/// This is adapted from Photokompressor's own FinderIntegration.swift, which solves the
/// identical problem and was validated end-to-end against real Apple-shipped reference
/// bundles (/System/Library/Services/*.workflow) — document.wflow's real location
/// (Contents/Resources, not Contents), AMAccepts.Types, AMParameterProperties shape, and
/// workflowMetaData's key set all carry over unchanged; only the accepted UTI
/// (`public.folder` in place of `public.image`/`com.apple.heic`), the shell command
/// (one folder via `"$1"`, matching `ShellRegistration.cs`'s `"%V"`, rather than every
/// selected file via `"$@"`), and the display strings change.
public enum FinderIntegration {
    public static let serviceName = "Start server here"
    private static let workflowName = "Start server here.workflow"

    /// Lets tests point registration at a scratch directory instead of the real
    /// ~/Library/Services — without this, running the test suite would read and (via
    /// unregister() in tearDown) could delete whatever real Quick Action registration is
    /// actually live on the machine.
    public static var servicesDirOverride: URL?

    private static var servicesDir: URL {
        servicesDirOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services", isDirectory: true)
    }

    private static var installedWorkflowURL: URL {
        servicesDir.appendingPathComponent(workflowName, isDirectory: true)
    }

    public enum FinderIntegrationError: Error, LocalizedError, Equatable {
        case appNotFound
        case runningFromRemovableVolume
        public var errorDescription: String? {
            switch self {
            case .appNotFound:
                return "Couldn't find the app bundle to point the Quick Action at."
            case .runningFromRemovableVolume:
                return "Move Serverlife to Applications (or anywhere on this Mac's own disk) first — "
                    + "it can't point the Quick Action at itself while running from the install disk image, "
                    + "since that path stops existing once you eject it."
            }
        }
    }

    public static func isRegistered() -> Bool {
        FileManager.default.fileExists(atPath: installedWorkflowURL.path)
    }

    /// `appPathOverride` exists for testing from a non-.app context (e.g. the CLI
    /// target); the real app never passes it and relies on `runningAppBundlePath()`.
    public static func register(appPathOverride: String? = nil) throws {
        guard let appPath = appPathOverride ?? runningAppBundlePath() else {
            throw FinderIntegrationError.appNotFound
        }
        // The Quick Action bakes in wherever the app happens to be running from right
        // now — if that's the mounted install .dmg, the right-click entry breaks the
        // moment the volume goes away. Refuse up front instead of silently registering
        // a path that won't last.
        if appPath.hasPrefix("/Volumes/") {
            throw FinderIntegrationError.runningFromRemovableVolume
        }

        let fm = FileManager.default
        try fm.createDirectory(at: servicesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: installedWorkflowURL)

        let contentsDir = installedWorkflowURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        try infoPlist().write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // Lives in Contents/Resources, not Contents itself — confirmed against the real
        // .workflow bundles under /System/Library/Services.
        try documentWorkflow(appPath: appPath)
            .write(to: resourcesDir.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)

        notifyServicesChanged()
    }

    public static func unregister() throws {
        try? FileManager.default.removeItem(at: installedWorkflowURL)
        notifyServicesChanged()
    }

    private static func runningAppBundlePath() -> String? {
        // Three levels up from the executable inside Contents/MacOS/Serverlife.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle.path : nil
    }

    private static func notifyServicesChanged() {
        // Tells Launch Services / the Services menu to re-scan ~/Library/Services.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        task.arguments = ["-flush"]
        try? task.run()
    }

    private static func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en_US</string>
            <key>CFBundleIdentifier</key>
            <string>gr.antidot.serverlife.quickaction</string>
            <key>CFBundleName</key>
            <string>\(serviceName)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(serviceName)</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                    <key>NSSendFileTypes</key>
                    <array>
                        <string>public.folder</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
    }

    private static func documentWorkflow(appPath: String) -> String {
        // Hands over exactly the one folder the Quick Action was invoked on — the
        // counterpart of ShellRegistration.cs's "\"%V\"" command line, and of
        // Photokompressor's own multi-file "$@" (which takes every selected file,
        // not applicable here since a folder verb only ever acts on one folder).
        let script = "open -a \"\(appPath)\" \"$1\""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AMApplicationBuild</key>
            <string>528</string>
            <key>AMApplicationVersion</key>
            <string>2.10</string>
            <key>AMDocumentVersion</key>
            <string>2</string>
            <key>actions</key>
            <array>
                <dict>
                    <key>action</key>
                    <dict>
                        <key>AMAccepts</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Optional</key>
                            <true/>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>AMActionVersion</key>
                        <string>2.0.3</string>
                        <key>AMApplication</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>AMParameterProperties</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <dict/>
                            <key>CheckedForUserDefaultShell</key>
                            <dict/>
                            <key>inputMethod</key>
                            <dict/>
                            <key>shell</key>
                            <dict/>
                            <key>source</key>
                            <dict/>
                        </dict>
                        <key>AMProvides</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.string</string>
                            </array>
                        </dict>
                        <key>ActionBundlePath</key>
                        <string>/System/Library/Automator/Run Shell Script.action</string>
                        <key>ActionName</key>
                        <string>Run Shell Script</string>
                        <key>ActionParameters</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <string>\(script)</string>
                            <key>CheckedForUserDefaultShell</key>
                            <true/>
                            <key>inputMethod</key>
                            <integer>1</integer>
                            <key>shell</key>
                            <string>/bin/bash</string>
                            <key>source</key>
                            <string></string>
                        </dict>
                        <key>BundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>CFBundleVersion</key>
                        <string>2.0.3</string>
                        <key>CanShowSelectedItemsWhenRun</key>
                        <false/>
                        <key>CanShowWhenRun</key>
                        <true/>
                        <key>Category</key>
                        <array>
                            <string>AMCategoryUtilities</string>
                        </array>
                        <key>Class Name</key>
                        <string>RunShellScriptAction</string>
                        <key>InputUUID</key>
                        <string>00000000-0000-0000-0000-000000000001</string>
                        <key>Keywords</key>
                        <array>
                            <string>Shell</string>
                            <string>Script</string>
                            <string>Command</string>
                            <string>Run</string>
                            <string>Unix</string>
                        </array>
                        <key>OutputUUID</key>
                        <string>00000000-0000-0000-0000-000000000002</string>
                        <key>UUID</key>
                        <string>00000000-0000-0000-0000-000000000003</string>
                        <key>UnlocalizedApplications</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>arguments</key>
                        <dict>
                            <key>0</key>
                            <dict>
                                <key>default value</key>
                                <integer>0</integer>
                                <key>name</key>
                                <string>inputMethod</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>0</string>
                            </dict>
                            <key>1</key>
                            <dict>
                                <key>default value</key>
                                <string></string>
                                <key>name</key>
                                <string>source</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>1</string>
                            </dict>
                            <key>2</key>
                            <dict>
                                <key>default value</key>
                                <false/>
                                <key>name</key>
                                <string>CheckedForUserDefaultShell</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>2</string>
                            </dict>
                            <key>3</key>
                            <dict>
                                <key>default value</key>
                                <string></string>
                                <key>name</key>
                                <string>COMMAND_STRING</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>3</string>
                            </dict>
                            <key>4</key>
                            <dict>
                                <key>default value</key>
                                <string>/bin/sh</string>
                                <key>name</key>
                                <string>shell</string>
                                <key>required</key>
                                <string>0</string>
                                <key>type</key>
                                <string>0</string>
                                <key>uuid</key>
                                <string>4</string>
                            </dict>
                        </dict>
                        <key>isViewVisible</key>
                        <true/>
                    </dict>
                    <key>isViewVisible</key>
                    <true/>
                </dict>
            </array>
            <key>connectors</key>
            <dict/>
            <key>workflowMetaData</key>
            <dict>
                <key>serviceApplicationBundleID</key>
                <string></string>
                <key>serviceApplicationPath</key>
                <string></string>
                <key>serviceInputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>serviceOutputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>serviceProcessesInput</key>
                <integer>1</integer>
                <key>workflowTypeIdentifier</key>
                <string>com.apple.Automator.servicesMenu</string>
            </dict>
        </dict>
        </plist>
        """
    }
}
