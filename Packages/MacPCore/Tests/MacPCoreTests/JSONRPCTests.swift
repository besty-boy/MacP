import Foundation
import Testing
@testable import MacPCore

@Suite("JSON-RPC 2.0 & JSONValue Codec")
struct JSONRPCTests {
    @Test("Decode and encode JSON-RPC IDs (int, string, null)")
    func jsonRPCIDRoundTrip() throws {
        let encoder = JSONRPCCodec.makeEncoder()
        let decoder = JSONRPCCodec.makeDecoder()

        let ids: [JSONRPCID] = [.int(42), .string("req-abc"), .null]
        for id in ids {
            let data = try encoder.encode(id)
            let decoded = try decoder.decode(JSONRPCID.self, from: data)
            #expect(decoded == id)
        }
    }

    @Test("Decode JSON-RPC request vs notification")
    func requestAndNotificationDecoding() throws {
        let decoder = JSONRPCCodec.makeDecoder()

        let reqJSON = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.data(using: .utf8)!
        let req = try decoder.decode(JSONRPCRequest.self, from: reqJSON)
        #expect(req.jsonrpc == "2.0")
        #expect(req.id == .int(1))
        #expect(req.method == "tools/list")
        #expect(req.isNotification == false)

        let notifJSON = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.data(using: .utf8)!
        let notif = try decoder.decode(JSONRPCRequest.self, from: notifJSON)
        #expect(notif.id == nil)
        #expect(notif.isNotification == true)
    }

    @Test("Encode NDJSON line terminates with a single newline")
    func ndjsonLineEncoding() throws {
        let response = JSONRPCResponse(id: .string("1"), result: ["ok": true])
        let line = try JSONRPCCodec.encodeLine(response)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        #expect(!text.dropLast().contains("\n"))
        #expect(text.contains("\"jsonrpc\":\"2.0\""))
        #expect(text.contains("\"ok\":true"))
    }

    @Test("JSONValue compactDescription summarizes safely")
    func compactDescription() {
        let args: JSONValue = [
            "shortcut_name": "Focus Work",
            "days": 3
        ]
        let summary = args.compactDescription
        #expect(summary.contains("shortcut_name"))
        #expect(summary.contains("Focus Work"))
        #expect(summary.contains("days: 3"))
    }
}
