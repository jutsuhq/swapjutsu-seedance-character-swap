import ComfyKit
import Foundation
import SwapjutsuAgent

/// The Model Context Protocol over stdio, written out by hand: JSON-RPC 2.0, one message per line, and only what an
/// agent needs to drive the app (initialize, ping, tools/list, tools/call). Every tool is one `AgentCommand` passed
/// through to the app; `send` makes the round trip and turns a failure to reach the app into an `AgentError`.
public struct MCPServer {
    /// Newest first. A client asking for one of these gets it; any other request gets the newest, and the client
    /// decides whether it can go on.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public typealias Send = (AgentCommand) async -> AgentResponse
    /// Hands an agent's file (a path as the agent gave it) to the app's inbox, into `folder`, named `name` plus the
    /// file's extension or as it is; returns the app's copy. See `Inbox`.
    public typealias Stage = (_ path: String, _ name: String?, _ folder: String) async throws(AgentError) -> URL

    let version: String
    let stage: Stage
    let send: Send
    /// Set by initialize; structured tool output exists from 2025-06-18 on.
    private var negotiated = protocolVersions[0]
    /// Who is calling, from initialize's `clientInfo`: shown on the clips it starts.
    private var client: String?

    public init(version: String, stage: @escaping Stage = { path, _, _ in URL(filePath: path) }, send: @escaping Send) {
        self.version = version
        self.stage = stage
        self.send = send
    }

    /// The reply to one line from the client, nil for a notification or a response.
    public mutating func reply(to line: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return Self.encode(error: -32700, "Parse error: not JSON.", id: .null)
        }
        guard case .object(let object) = message else {
            // Batches were dropped from the protocol in 2025-06-18, and no client sends them over stdio.
            return Self.encode(error: -32600, "Invalid request: expected one JSON-RPC object.", id: .null)
        }
        // A notification has no id, and a response to us has no method; neither gets an answer.
        guard let id = object["id"], let method = object["method"]?.string else { return nil }
        let params = object["params"]?.object ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string
            negotiated = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            let info = params["clientInfo"]
            client = (info?["title"]?.string ?? info?["name"]?.string).flatMap {
                $0.isEmpty ? nil : String($0.prefix(64))
            }
            return Self.encode(
                result: [
                    "protocolVersion": .string(negotiated),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "swapjutsu", "title": "Swapjutsu", "version": .string(version)],
                    "instructions": .string(Self.instructions),
                ], id: id)
        case "ping":
            return Self.encode(result: [:], id: id)
        case "tools/list":
            return Self.encode(result: ["tools": .array(Tool.allCases.map(\.definition))], id: id)
        case "tools/call":
            guard let name = params["name"]?.string, let tool = Tool(rawValue: name) else {
                return Self.encode(error: -32602, "Unknown tool '\(params["name"]?.string ?? "")'.", id: id)
            }
            switch await tool.command(params["arguments"]?.object ?? [:], Tool.Context(client: client, stage: stage)) {
            case .success(let command): return Self.encode(result: result(of: await send(command)), id: id)
            case .failure(.invalid(let message)): return Self.encode(error: -32602, message, id: id)
            case .failure(.refused(let error)):
                return Self.encode(result: result(of: AgentResponse(error: error)), id: id)
            }
        default:
            return Self.encode(error: -32601, "Method not found: \(method).", id: id)
        }
    }

    /// The app's answer as tool output: its JSON as text for every client, and as structured content for those that
    /// read it. An `AgentError` is a tool error the model sees, with its code, message and what to do next.
    private func result(of response: AgentResponse) -> JSONValue {
        var answer = (try? JSONDecoder().decode(JSONValue.self, from: AgentWire.line(response))) ?? [:]
        answer["id"] = nil
        let text = (try? AgentWire.line(answer)).map { String(decoding: $0.dropLast(), as: UTF8.self) } ?? "{}"
        var result: JSONValue = [
            "content": [["type": "text", "text": .string(text)]], "isError": .bool(response.error != nil),
        ]
        if negotiated >= "2025-06-18" { result["structuredContent"] = answer }
        return result
    }

    private static let instructions = """
        Drives the Swapjutsu app on this Mac. Call capabilities first to see what the app can do now. Agents are off \
        until the person turns on Settings › Agents › Allow agents in Swapjutsu; until then every tool returns the \
        error agents_off, and the person has to turn it on. The free half of a character swap: prepare a video \
        into clips, wait on clips for prep to finish, look at the people it found (face crops, review.mp4), then \
        set_characters with an image per replaced person. Then the paid half: quote what a render costs, render \
        (draft first; finalize a good draft at 1080p within 7 days), and follow it with clips or by repeating the \
        same request_id. A render is sent only when the top of its estimate is within your max_cost and the \
        person's daily agent budget (Settings › Agents, $0 unless they set one); otherwise it waits in Jobs for the \
        person to send, so tell them. library_search lists the finished drafts and finals with their files; show \
        opens a page, a clip or a result for the person. Nothing here deletes.
        """

    private static func encode(result: JSONValue, id: JSONValue) -> Data? {
        try? AgentWire.line(["jsonrpc": "2.0", "id": id, "result": result] as JSONValue)
    }

    private static func encode(error code: Int, _ message: String, id: JSONValue) -> Data? {
        try? AgentWire.line(
            ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
                as JSONValue)
    }
}
