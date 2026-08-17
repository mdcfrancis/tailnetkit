import Foundation

/// Stand-in for apps whose pairing QR carries nothing beyond the transport
/// settings. `PairingPayload<NoExtras>` is the plain form.
public struct NoExtras: Codable, Sendable, Equatable {
    public init() {}
}

/// Everything a client needs to reach a server, in one scannable blob.
///
/// Wire format is JSON with sorted keys:
///
///     {"app":{…},"host":"100.x.y.z","port":8945,"token":"…","ts_key":"tskey-…","v":1}
///
/// The module owns `v`/`host`/`port`/`token`/`ts_key`; everything the
/// embedding app needs goes in `app`, typed as `Extra`. Nesting app config
/// under one key rather than spreading it across the top level is what keeps
/// a client's decoder from colliding with a future transport field.
///
/// Unknown keys are ignored on decode and `app` is optional, so a server that
/// starts sending extras still pairs a client built before they existed, and
/// vice versa.
public struct PairingPayload<Extra: Codable & Sendable>: Codable, Sendable {

    /// Bumped only for a breaking change to the transport fields. Adding app
    /// extras does not need a bump — that is the point of `app`.
    public static var currentVersion: Int { 1 }

    public var version: Int
    /// Tailnet address or MagicDNS name of the server.
    public var host: String
    public var port: Int
    /// Bearer token for the server's API.
    public var token: String
    /// Optional tailnet auth key, so the client joins without its own
    /// interactive sign-in. Absent means the client authenticates itself.
    public var tailnetAuthKey: String?
    /// App-specific configuration.
    public var app: Extra?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case host
        case port
        case token
        case tailnetAuthKey = "ts_key"
        case app
    }

    public init(
        host: String,
        port: Int,
        token: String,
        tailnetAuthKey: String? = nil,
        app: Extra? = nil,
        version: Int = PairingPayload.currentVersion
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.token = token
        // Normalise "" to absent so an unset key never rides along as an
        // empty string a client would try to join with.
        self.tailnetAuthKey = (tailnetAuthKey?.isEmpty ?? true) ? nil : tailnetAuthKey
        self.app = app
    }

    /// JSON string for the QR. Sorted keys keep the encoding stable, which
    /// keeps the rendered QR stable across launches.
    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Decodes a scanned string, returning nil for anything that isn't a
    /// usable payload — a wrong version, a blank host or a nonsense port. The
    /// camera will happily hand over any QR in frame, including ones from
    /// other apps, so this is the gate.
    public static func decode(_ string: String) -> Self? {
        guard
            let payload = try? JSONDecoder().decode(
                Self.self, from: Data(string.utf8)),
            payload.version == Self.currentVersion,
            !payload.host.isEmpty,
            payload.port > 0, payload.port <= 65535
        else { return nil }
        return payload
    }
}
