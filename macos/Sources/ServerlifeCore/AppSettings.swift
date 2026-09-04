import Foundation

/// App-level preferences — take effect immediately when toggled, not tied to any batch
/// of work.
public struct AppSettings: Equatable, Sendable {
    public var alwaysOnTop: Bool = false

    public init() {}

    // Decoded leniently, field by field, rather than via a synthesized Decodable: the
    // synthesized decoder throws on any missing key, so adding a setting later would
    // silently reset every existing user's settings.json back to defaults instead of
    // just defaulting the new field. Cheap to build in now, expensive to retrofit once
    // a real user's settings.json is already missing a key.
    private enum CodingKeys: String, CodingKey {
        case alwaysOnTop
    }
}

extension AppSettings: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? defaults.alwaysOnTop
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alwaysOnTop, forKey: .alwaysOnTop)
    }
}
