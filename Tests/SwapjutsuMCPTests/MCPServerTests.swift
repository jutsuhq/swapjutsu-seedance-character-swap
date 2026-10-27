import ComfyKit
import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuMCP

/// What an MCP client sees over stdio, against a stand-in for the app.
struct MCPServerTests {
    let capabilities = AgentCapabilities(appVersion: "0.1.0", hasComfyKey: true, depthModel: .ready)

    func server(_ answer: @escaping (AgentCommand) -> AgentResponse) -> MCPServer {
        MCPServer(version: "0.1.0") { answer($0) }
    }

    func call(_ server: inout MCPServer, _ line: String) async throws -> JSONValue? {
        guard let reply = await server.reply(to: Data(line.utf8)) else { return nil }
        #expect(reply.last == UInt8(ascii: "\n"))
        #expect(!reply.dropLast().contains(UInt8(ascii: "\n")))
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    @Test(arguments: [
        ("2025-06-18", "2025-06-18"), ("2024-11-05", "2024-11-05"), ("2099-01-01", "2025-11-25"),
    ])
    func initializeAgreesOnAVersion(requested: String, agreed: String) async throws {
        var server = server { _ in AgentResponse() }
        let reply = try #require(
            try await call(
                &server,
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(requested)","#
                    + #""capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == .string(agreed))
        #expect(reply["result"]?["capabilities"] == ["tools": ["listChanged": false]])
        #expect(reply["result"]?["serverInfo"]?["version"] == "0.1.0")
    }

    @Test func notificationsAndResponsesGetNoReply() async throws {
        var server = server { _ in AgentResponse() }
        #expect(try await call(&server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try await call(&server, #"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
        let ping = try await call(&server, #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        #expect(ping == ["jsonrpc": "2.0", "id": "p", "result": [:]])
    }

    @Test func listsBothTools() async throws {
        var server = server { _ in AgentResponse() }
        let reply = try await call(&server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools) = reply?["result"]?["tools"] else {
            Issue.record("no tools in \(String(describing: reply))")
            return
        }
        #expect(
            tools.compactMap { $0["name"]?.string }
                == [
                    "capabilities", "show", "prepare", "clips", "set_characters", "prepare_again", "quote", "render",
                    "finalize", "job_action", "library_search", "correct_target", "frames",
                ])
        #expect(tools[12]["inputSchema"]?["required"] == ["render"])
        #expect(tools[12]["inputSchema"]?["properties"]?["count"]?["maximum"] == 12)
        #expect(tools[11]["inputSchema"]?["required"] == ["clip", "frame"])
        #expect(tools[7]["inputSchema"]?["required"] == ["clip", "quality", "request_id", "max_cost"])
        #expect(tools[7]["annotations"]?["openWorldHint"] == true)
        #expect(tools[9]["inputSchema"]?["properties"]?["action"]?["enum"] == ["cancel", "retry"])
        #expect(tools[2]["inputSchema"]?["required"] == ["video", "request_id"])
        #expect(
            tools[2]["inputSchema"]?["properties"]?["control"]?["enum"] == ["depth", "hybrid-hands", "hybrid-body"])
        #expect(tools[3]["inputSchema"]?["properties"]?["wait_seconds"]?["maximum"] == 60)
        let screen = tools[1]["inputSchema"]?["properties"]?["screen"]
        #expect(screen?["enum"] == ["create", "jobs", "library", "settings"])
        #expect(tools[1]["inputSchema"]?["required"] == nil, "one of screen, clip or result")
        #expect(tools[1]["inputSchema"]?["properties"]?["result"]?["type"] == "string")
        #expect(tools[10]["inputSchema"]?["properties"]?["limit"]?["maximum"] == 50)
        #expect(tools[10]["annotations"]?["readOnlyHint"] == true)
    }

    @Test func callsPassTheCommandThroughAndReturnTheAppsAnswer() async throws {
        var sent: [AgentCommand] = []
        var server = MCPServer(version: "0.1.0") { [capabilities] command in
            sent.append(command)
            if case .show(.screen(let screen)) = command { return AgentResponse(id: "app", shown: screen) }
            return AgentResponse(id: "app", capabilities: capabilities)
        }
        let info = try await call(
            &server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities"}}"#)
        let expected: JSONValue = [
            "capabilities": [
                "appVersion": "0.1.0", "depthModel": "ready", "hasComfyKey": true, "protocolVersion": 1,
                "helperVersion": "0.1.0",
            ]
        ]
        #expect(info?["result"]?["isError"] == false)
        // The app's request id is the binary's business, not the client's.
        #expect(info?["result"]?["structuredContent"] == expected)
        let text = try #require(info?["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == expected)

        let shown = try await call(
            &server,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"show","arguments":{"screen":"jobs"}}}"#)
        #expect(shown?["result"]?["structuredContent"] == ["shown": "jobs"])
        #expect(sent == [.capabilities, .show(.screen(.jobs))])
    }

    /// An MCP client keeps the helper it started, so after an update the agent may talk to an older one.
    @Test func anOlderHelperTellsTheAgentToReconnect() async throws {
        var server = MCPServer(version: "0.1.9") { _ in
            AgentResponse(capabilities: AgentCapabilities(appVersion: "0.1.10", hasComfyKey: true, depthModel: .ready))
        }
        let info = try await call(
            &server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities"}}"#)
        let capabilities = info?["result"]?["structuredContent"]?["capabilities"]
        #expect(capabilities?["helperVersion"] == "0.1.9")
        #expect(capabilities?["helperNote"]?.string?.contains("Reconnect the swapjutsu MCP server") == true)

        for (helper, app) in [("0.1.10", "0.1.10"), ("0.2.0", "0.1.10"), ("development", "0.2.0"), ("0.1.0", "development")] {
            var answer = AgentCapabilities(appVersion: app, hasComfyKey: true, depthModel: .ready)
            answer.noteHelper(helper)
            #expect(answer.helperNote == nil, "\(helper) with app \(app)")
        }
    }

    @Test func anAppErrorIsAToolErrorWithWhatToDoNext() async throws {
        var server = server { _ in AgentResponse(error: .agentsOff) }
        let reply = try await call(
            &server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"capabilities"}}"#)
        #expect(reply?["result"]?["isError"] == true)
        #expect(reply?["result"]?["structuredContent"]?["error"]?["code"] == "agents_off")
        let text = try #require(reply?["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(text.contains("Settings › Agents › Allow agents"))
    }

    @Test func structuredContentOnlyForClientsThatKnowIt() async throws {
        var server = server { _ in AgentResponse(shown: .jobs) }
        _ = try await call(
            &server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let reply = try await call(
            &server,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show","arguments":{"screen":"jobs"}}}"#)
        #expect(reply?["result"]?["structuredContent"] == nil)
        #expect(reply?["result"]?["content"]?.array?.first?["text"] == #"{"shown":"jobs"}"#)
    }

    @Test(arguments: [
        ("not json", -32700.0),
        (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, -32600),
        (#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, -32601),
        (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete"}}"#, -32602),
        (
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show","arguments":{"screen":"trash"}}}"#,
            -32602
        ),
        (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show","arguments":{}}}"#, -32602),
        (
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show","arguments":{"clip":"c","result":"r"}}}"#,
            -32602
        ),
    ])
    func badRequestsGetJSONRPCErrors(line: String, code: Double) async throws {
        var server = server { _ in
            Issue.record("sent a command")
            return AgentResponse()
        }
        let reply = try await call(&server, line)
        #expect(reply?["error"]?["code"] == .number(code))
        #expect(reply?["error"]?["message"]?.string?.isEmpty == false)
    }
}

/// The prep tools: snake_case arguments become typed commands, files go to the inbox first, and anything wrong with
/// the arguments is a tool error the model can read. The stand-in for the app records each upload and answers with
/// where the app would put it.
struct MCPPrepToolTests {
    let inbox = FileManager.default.temporaryDirectory.appending(path: "mcp-inbox-\(UUID().uuidString)")
    let uploads = Uploads()

    final class Uploads: @unchecked Sendable {
        var sent: [(source: URL, command: UploadCommand)] = []
    }

    func call(_ server: inout MCPServer, _ name: String, _ arguments: String) async throws -> JSONValue? {
        let line =
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        guard let reply = await server.reply(to: Data(line.utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    func server(_ sent: @escaping (AgentCommand) -> Void) -> MCPServer {
        let (folder, uploads) = (inbox, uploads)
        let files = Inbox(workingDirectory: inbox.deletingLastPathComponent())
        let stage: MCPServer.Stage = { (path, name, request) async throws(AgentError) -> URL in
            let upload = try files.upload(path, name: name, folder: request)
            uploads.sent.append(upload)
            return folder.appending(path: "\(request)/\(upload.command.name)")
        }
        return MCPServer(version: "0.1.0", stage: stage) { command in
            sent(command)
            return AgentResponse(clips: [])
        }
    }

    @Test func prepareSendsTheVideoToTheInboxAndNamesTheClient() async throws {
        let video = inbox.deletingLastPathComponent().appending(path: "agent \(UUID().uuidString).mov")
        try Data("video".utf8).write(to: video)
        defer { try? FileManager.default.removeItem(at: video) }
        var commands: [AgentCommand] = []
        var server = server { commands.append($0) }
        _ = await server.reply(
            to: Data(
                #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#.utf8))
        let reply = try await call(
            &server, "prepare",
            #"{"video":"\#(video.lastPathComponent)","request_id":"r-1","ranges":[{"start":0,"end":5}],"#
                + #""target":[2],"face_guide":true,"control":"hybrid-hands"}"#)
        #expect(reply?["result"]?["isError"] == false)
        let folder = try #require(uploads.sent.first?.command.folder)
        let expected = inbox.appending(path: "\(folder)/\(video.lastPathComponent)")
        #expect(
            commands == [
                .prepare(
                    PrepareCommand(
                        requestID: "r-1", video: video.lastPathComponent, file: expected.path(percentEncoded: false),
                        ranges: [AgentRange(start: 0, end: 5)], target: .people([2]), faceGuide: true,
                        control: .hybridHands, client: "claude-code"))
            ])
        #expect(uploads.sent.map(\.source) == [video.resolvingSymlinksInPath()], "relative to where it started")
        #expect(uploads.sent.map(\.command) == [UploadCommand(folder: folder, name: video.lastPathComponent, size: 5)])
    }

    /// The app refuses a repeated request_id with other inputs only after the upload, so the upload must not land
    /// on the video a clip of the first call still reads.
    @Test func eachPrepareUploadsIntoAFolderOfItsOwn() async throws {
        let video = inbox.deletingLastPathComponent().appending(path: "clip-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: video)
        defer { try? FileManager.default.removeItem(at: video) }
        var commands: [AgentCommand] = []
        var server = server { commands.append($0) }
        for _ in 0..<2 { _ = try await call(&server, "prepare", #"{"video":"\#(video.path)","request_id":"r-1"}"#) }
        let files = commands.compactMap { command -> String? in
            guard case .prepare(let prepare) = command else { return nil }
            return prepare.file
        }
        #expect(files.count == 2 && Set(files).count == 2)
        let folders = uploads.sent.map(\.command.folder)
        #expect(Set(folders).count == 2 && !folders.contains("r-1"))
    }

    @Test func setCharactersSendsAnImagePerPerson() async throws {
        let image = inbox.deletingLastPathComponent().appending(path: "face-\(UUID().uuidString).png")
        try Data("png".utf8).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        var commands: [AgentCommand] = []
        var server = server { commands.append($0) }
        _ = try await call(
            &server, "set_characters",
            #"{"clip":"c","characters":[{"person":2,"image":"\#(image.path)"}],"remove_background":true}"#)
        guard case .setCharacters(let command) = commands.first, let character = command.characters?.first else {
            Issue.record("sent \(commands)")
            return
        }
        #expect(command.clip == "c" && command.removeBackground == true && command.prompt == nil)
        #expect(character.person == 2 && character.image == image.path)
        #expect(character.file.hasPrefix(inbox.path) && character.file.hasSuffix("/person-2.png"))
        #expect(uploads.sent.map(\.command.name) == ["person-2.png"])
    }

    @Test func renderAndFinalizeNameTheClientAndTheirLimit() async throws {
        var commands: [AgentCommand] = []
        var server = server { commands.append($0) }
        _ = await server.reply(
            to: Data(
                #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#.utf8))
        _ = try await call(
            &server, "render", #"{"clip":"c","quality":"final1080","request_id":"r-2","max_cost":3.5}"#)
        _ = try await call(&server, "finalize", #"{"render":"d","request_id":"f-1","max_cost":1}"#)
        _ = try await call(&server, "quote", #"{"clip":"c","quality":"draft"}"#)
        _ = try await call(&server, "job_action", #"{"job":"d","action":"cancel"}"#)
        #expect(
            commands == [
                .render(
                    RenderCommand(clip: "c", quality: .final1080, requestID: "r-2", maxCost: 3.5, client: "claude-code")
                ),
                .finalize(FinalizeCommand(render: "d", requestID: "f-1", maxCost: 1, client: "claude-code")),
                .quote(QuoteCommand(clip: "c", quality: .draft)),
                .jobAction(JobActionCommand(job: "d", action: .cancel)),
            ])
    }

    @Test func showAndLibrarySearchPassTheirArgumentsThrough() async throws {
        var commands: [AgentCommand] = []
        var server = server { commands.append($0) }
        _ = try await call(&server, "show", #"{"clip":"c1"}"#)
        _ = try await call(&server, "show", #"{"result":"r1"}"#)
        _ = try await call(&server, "library_search", #"{}"#)
        _ = try await call(
            &server, "library_search", #"{"text":"beach","quality":"final1080","limit":5,"cursor":"r9"}"#)
        _ = try await call(&server, "frames", #"{"render":"r1","seconds":[0.5,2]}"#)
        #expect(
            commands == [
                .show(.clip("c1")), .show(.result("r1")), .librarySearch(LibrarySearchCommand()),
                .librarySearch(LibrarySearchCommand(text: "beach", quality: .final1080, limit: 5, cursor: "r9")),
                .frames(FramesCommand(render: "r1", seconds: [0.5, 2])),
            ])
    }

    @Test(arguments: [
        ("render", #"{"clip":"c","quality":"draft","request_id":"r"}"#, "bad_request", "needs max_cost"),
        ("render", #"{"clip":"c","quality":"8k","request_id":"r","max_cost":1}"#, "bad_request", "quality"),
        ("finalize", #"{"render":"d","request_id":"r","max_cost":"lots"}"#, "bad_request", "max_cost"),
        ("job_action", #"{"job":"d","action":"delete"}"#, "bad_request", "action"),
        ("prepare", #"{"request_id":"r"}"#, "bad_request", "needs video"),
        ("prepare", #"{"video":"/nowhere/x.mov","request_id":"../r"}"#, "bad_request", "request_id"),
        ("prepare", #"{"video":"/nowhere/x.mov","request_id":"r"}"#, "file_refused", "/nowhere/x.mov"),
        ("prepare", #"{"video":"/nowhere/x.mov","request_id":"r","ranges":[{"start":"0"}]}"#, "bad_request", "ranges"),
        ("clips", #"{"wait_seconds":"ten"}"#, "bad_request", "wait_seconds"),
        ("set_characters", #"{"characters":[]}"#, "bad_request", "needs clip"),
        ("prepare_again", #"{"clip":"c","target":"nobody"}"#, "bad_request", "target"),
        ("library_search", #"{"limit":"many"}"#, "bad_request", "limit"),
        ("library_search", #"{"quality":"best"}"#, "bad_request", "quality"),
        ("frames", #"{"count":2}"#, "bad_request", "needs render"),
    ])
    func badArgumentsAreToolErrorsAndNothingIsSent(
        tool: String, arguments: String, code: String, says: String
    )
        async throws
    {
        var server = server { Issue.record("sent \($0)") }
        let reply = try await call(&server, tool, arguments)
        #expect(reply?["result"]?["isError"] == true)
        #expect(reply?["result"]?["structuredContent"]?["error"]?["code"] == .string(code))
        let message = reply?["result"]?["structuredContent"]?["error"]?["message"]?.string ?? ""
        #expect(message.contains(says), "\(message)")
        #expect(uploads.sent.isEmpty, "nothing was sent")
    }
}

extension JSONValue {
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}
