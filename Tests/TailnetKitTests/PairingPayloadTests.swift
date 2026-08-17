import XCTest

@testable import TailnetKit

struct DemoExtras: Codable, Sendable, Equatable {
    var privateMode: Bool
    var preferredModel: String?
}

final class PairingPayloadTests: XCTestCase {

    func testRoundTripsTransportFields() throws {
        let payload = PairingPayload<NoExtras>(
            host: "100.64.1.2", port: 8945, token: "abc123",
            tailnetAuthKey: "tskey-auth-xyz")

        let decoded = try XCTUnwrap(
            PairingPayload<NoExtras>.decode(payload.encoded()))

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.host, "100.64.1.2")
        XCTAssertEqual(decoded.port, 8945)
        XCTAssertEqual(decoded.token, "abc123")
        XCTAssertEqual(decoded.tailnetAuthKey, "tskey-auth-xyz")
    }

    func testRoundTripsAppExtras() throws {
        let extras = DemoExtras(privateMode: true, preferredModel: "flux")
        let payload = PairingPayload(
            host: "host", port: 1, token: "t", app: extras)

        let decoded = try XCTUnwrap(
            PairingPayload<DemoExtras>.decode(payload.encoded()))
        XCTAssertEqual(decoded.app, extras)
    }

    /// The wire format that shipped before extras existed. An already-paired
    /// device must keep working, so this must decode unchanged.
    func testDecodesPayloadWithNoAppKey() throws {
        let legacy = #"{"host":"100.64.1.2","port":8945,"token":"abc","ts_key":"tskey-1","v":1}"#

        let decoded = try XCTUnwrap(PairingPayload<NoExtras>.decode(legacy))
        XCTAssertEqual(decoded.host, "100.64.1.2")
        XCTAssertEqual(decoded.port, 8945)
        XCTAssertEqual(decoded.token, "abc")
        XCTAssertEqual(decoded.tailnetAuthKey, "tskey-1")
        XCTAssertNil(decoded.app)
    }

    /// A client that knows nothing about extras must still pair with a server
    /// that sends them — forward compatibility in the other direction.
    func testIgnoresUnknownAppExtras() throws {
        let future = #"{"app":{"somethingNew":42},"host":"h","port":80,"token":"t","v":1}"#
        XCTAssertNotNil(PairingPayload<NoExtras>.decode(future))
    }

    /// The encoded form is what gets rendered into a QR; a stable key order
    /// keeps the image stable between launches.
    func testEncodingIsStable() throws {
        let payload = PairingPayload<NoExtras>(
            host: "h", port: 80, token: "t", tailnetAuthKey: "k")
        XCTAssertEqual(try payload.encoded(), try payload.encoded())
        XCTAssertEqual(
            try payload.encoded(),
            #"{"host":"h","port":80,"token":"t","ts_key":"k","v":1}"#)
    }

    /// An unset auth key must be absent, not an empty string a client would
    /// try to join with.
    func testEmptyAuthKeyIsOmitted() throws {
        let payload = PairingPayload<NoExtras>(
            host: "h", port: 80, token: "t", tailnetAuthKey: "")
        XCTAssertFalse(try payload.encoded().contains("ts_key"))
        XCTAssertNil(payload.tailnetAuthKey)
    }

    /// The camera hands over any QR in frame, including other apps'.
    func testRejectsUnusablePayloads() {
        let cases = [
            "not json at all",
            "https://example.com",
            #"{"host":"h","port":80,"token":"t","v":2}"#,      // wrong version
            #"{"host":"","port":80,"token":"t","v":1}"#,        // blank host
            #"{"host":"h","port":0,"token":"t","v":1}"#,        // bad port
            #"{"host":"h","port":70000,"token":"t","v":1}"#,    // out of range
            #"{"host":"h","port":80,"v":1}"#,                   // no token
        ]
        for input in cases {
            XCTAssertNil(
                PairingPayload<NoExtras>.decode(input),
                "should have rejected: \(input)")
        }
    }

    func testRendersQRImage() throws {
        let payload = PairingPayload<NoExtras>(host: "h", port: 80, token: "t")
        let image = try XCTUnwrap(PairingQR.image(for: payload))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertEqual(image.width, image.height)
    }
}
