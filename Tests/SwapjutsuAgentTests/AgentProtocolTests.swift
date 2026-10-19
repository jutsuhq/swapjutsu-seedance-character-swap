import Foundation
import SwapjutsuAgent
import Testing

/// The wire format is what the app and `swapjutsu` agree on across versions, so it is pinned here byte for byte.
struct AgentProtocolTests {
    @Test func requestsAreFlatJSONLines() throws {
        let show = try AgentWire.line(AgentRequest(.show(.screen(.jobs)), id: "7"))
        #expect(
            String(decoding: show, as: UTF8.self) == #"{"command":"show","id":"7","screen":"jobs","version":1}"# + "\n")
        let capabilities = try AgentWire.line(AgentRequest(.capabilities))
        #expect(String(decoding: capabilities, as: UTF8.self) == #"{"command":"capabilities","version":1}"# + "\n")
    }

    @Test func requestsRoundTrip() throws {
        let shows = AgentScreen.allCases.map { AgentRequest(.show(.screen($0))) }
        let library = [
            AgentRequest(.show(.clip("c1")), id: "s"), AgentRequest(.show(.result("r1"))),
            AgentRequest(.librarySearch(LibrarySearchCommand())),
            AgentRequest(.librarySearch(LibrarySearchCommand(text: "beach", quality: .draft, limit: 5, cursor: "x"))),
        ]
        for request in [AgentRequest(.capabilities, id: "a")] + shows + library {
            let (id, decoded) = AgentWire.request(from: try AgentWire.line(request).dropLast())
            #expect(id == request.id)
            #expect(try decoded.get() == request)
        }
    }

    @Test func responsesCarryOnlyTheirResult() throws {
        let capabilities = AgentResponse(
            id: "1", capabilities: AgentCapabilities(appVersion: "0.1.0", hasComfyKey: true, depthModel: .ready))
        #expect(
            String(decoding: try AgentWire.line(capabilities), as: UTF8.self)
                == #"{"capabilities":{"appVersion":"0.1.0","depthModel":"ready","hasComfyKey":true,"#
                + #""protocolVersion":1},"id":"1"}"# + "\n")
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: try AgentWire.line(capabilities))
        #expect(decoded == capabilities)
    }

    @Test func errorsHaveACodeRetryableAndNext() throws {
        let line = try AgentWire.line(AgentResponse(id: "2", error: .agentsOff))
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(Set(error.keys) == ["code", "message", "retryable", "next"])
        #expect(error["code"] as? String == "agents_off")
        #expect(error["retryable"] as? Bool == true)
        #expect((error["next"] as? String)?.contains("Allow agents") == true)
    }

    @Test func aCodeFromANewerAppStillDecodes() throws {
        let line = Data(#"{"error":{"code":"budget_spent","message":"m","retryable":false}}"#.utf8)
        let error = try #require(try JSONDecoder().decode(AgentResponse.self, from: line).error)
        #expect(error.code.rawValue == "budget_spent")
        #expect(error.next == nil)
    }

    @Test(arguments: [
        (#"{"version":2,"id":"x","command":"teleport"}"#, "unsupported_version", "x"),
        (#"{"version":1,"id":"x","command":"teleport"}"#, "unknown_command", "x"),
        (#"{"version":1,"id":"x","command":"show"}"#, "bad_request", "x"),
        (#"{"version":1,"command":"show","screen":"trash"}"#, "bad_request", nil),
        (#"{"command":"capabilities"}"#, "bad_request", nil),
        (#"{"version":1,"id":"p","command":"prepare","video":"v.mp4","file":"f.mp4"}"#, "bad_request", "p"),
        (
            #"{"version":1,"command":"prepare","requestId":"r","video":"v","file":"f","target":"some"}"#,
            "bad_request", nil
        ),
        (#"{"version":1,"command":"clips","waitSeconds":"soon"}"#, "bad_request", nil),
        (#"{"version":1,"command":"set_characters"}"#, "bad_request", nil),
        (#"{"version":1,"command":"render","clip":"c","quality":"draft","requestId":"r"}"#, "bad_request", nil),
        (#"{"version":1,"command":"quote","clip":"c","quality":"4k"}"#, "bad_request", nil),
        (#"{"version":1,"command":"job_action","job":"j","action":"delete"}"#, "bad_request", nil),
        ("not json", "bad_request", nil),
    ])
    func malformedRequestsAreRefusedWithTheirId(line: String, code: String, id: String?) {
        let (decodedID, request) = AgentWire.request(from: Data(line.utf8))
        #expect(decodedID == id)
        guard case .failure(let error) = request else {
            Issue.record("decoded \(line)")
            return
        }
        #expect(error.code.rawValue == code)
        #expect(!error.retryable)
        #expect(error.next != nil)
    }

    /// The prep commands keep the flat shape: their fields sit next to version, id and command.
    @Test func prepCommandsAreFlatAndRoundTrip() throws {
        let prepare = AgentRequest(
            .prepare(
                PrepareCommand(
                    requestID: "r1", video: "/tmp/a/clip.mov", file: "/inbox/r1/clip.mov",
                    ranges: [AgentRange(start: 0, end: 4.5)], target: .people([2, 3]), faceGuide: true,
                    client: "claude-code")), id: "9")
        #expect(
            String(decoding: try AgentWire.line(prepare), as: UTF8.self)
                == #"{"client":"claude-code","command":"prepare","faceGuide":true,"file":"/inbox/r1/clip.mov","#
                + #""id":"9","ranges":[{"end":4.5,"start":0}],"requestId":"r1","target":[2,3],"#
                + #""version":1,"video":"/tmp/a/clip.mov"}"# + "\n")
        let commands: [AgentCommand] = [
            prepare.command,
            .prepare(PrepareCommand(requestID: "r2", video: "v", file: "f", target: .all)),
            .clips(ClipsCommand()),
            .clips(ClipsCommand(clip: "c", waitSeconds: 30)),
            .setCharacters(
                SetCharactersCommand(
                    clip: "c", characters: [.init(person: 1, image: "/a.png", file: "/inbox/x/person-1.png")],
                    removeBackground: false, prompt: "Rain.")),
            .prepareAgain(PrepareAgainCommand(clip: "c", target: .main, faceGuide: false, control: .hybridBody)),
            .correctTarget(CorrectTargetCommand(clip: "c", person: 2, frame: 72, x: 250, y: 400)),
            .correctTarget(CorrectTargetCommand(clip: "c", frame: 3, mask: "/a.png", file: "/inbox/x/mask.png")),
            .upload(UploadCommand(folder: "r1", name: "My clip (1).mov", size: 5)),
        ]
        for command in commands {
            let (_, decoded) = AgentWire.request(from: try AgentWire.line(AgentRequest(command)).dropLast())
            #expect(try decoded.get().command == command)
        }
    }

    /// The render commands keep the flat shape too; job_action names its target `job`, since `id` is the request's.
    @Test func renderCommandsAreFlatAndRoundTrip() throws {
        let render = AgentRequest(
            .render(RenderCommand(clip: "c", quality: .final720, requestID: "r1", maxCost: 1.5, client: "claude-code")),
            id: "4")
        #expect(
            String(decoding: try AgentWire.line(render), as: UTF8.self)
                == #"{"client":"claude-code","clip":"c","command":"render","id":"4","maxCost":1.5,"#
                + #""quality":"final720","requestId":"r1","version":1}"# + "\n")
        let action = AgentRequest(.jobAction(JobActionCommand(job: "j", action: .retry)), id: "5")
        #expect(
            String(decoding: try AgentWire.line(action), as: UTF8.self)
                == #"{"action":"retry","command":"job_action","id":"5","job":"j","version":1}"# + "\n")
        let commands: [AgentCommand] = [
            render.command, action.command,
            .quote(QuoteCommand(clip: "c", quality: .draft)),
            .render(RenderCommand(clip: "c", quality: .draft, requestID: "r2", maxCost: 0)),
            .finalize(FinalizeCommand(render: "d", requestID: "f1", maxCost: 2, client: "x")),
            .jobAction(JobActionCommand(job: "j", action: .cancel)),
        ]
        for command in commands {
            let (_, decoded) = AgentWire.request(from: try AgentWire.line(AgentRequest(command)).dropLast())
            #expect(try decoded.get().command == command)
        }
    }

    @Test func aQuoteIsAnEstimateWithTheBudgetLeft() throws {
        let quote = AgentQuote(
            clip: "c", quality: .draft, seconds: 5, low: 0.44, high: 0.89,
            budget: AgentBudget(daily: 0.15, spentToday: 0.1))
        #expect(quote.budget.remaining == 0.05)
        let line = try AgentWire.line(AgentResponse(quote: quote))
        #expect(String(decoding: line, as: UTF8.self).contains(#""currency":"USD","high":0.89,"isEstimate":true"#))
        #expect(try AgentWire.decoder.decode(AgentResponse.self, from: line).quote == quote)
        #expect(AgentBudget(daily: 1, spentToday: 3).remaining == 0)
    }

    @Test func clipsComeBackWithTheirOrigin() throws {
        let clip = AgentClip(
            id: "c", title: "t", folder: "/f", stage: "prepared", progress: "", range: nil, target: .all,
            faceGuide: false, removeBackground: false, prompt: "", characters: [], missingCharacters: 1,
            people: [AgentPerson(id: 1, crop: "/f/identities/1.jpg", screenShare: 1, isTarget: true, character: nil)],
            warnings: [], control: "/f/control.mp4", review: "/f/review.mp4", renders: 0,
            origin: AgentOrigin(
                client: "claude-code", requestID: "r1", started: Date(timeIntervalSince1970: 1_800_000_000)))
        let line = try AgentWire.line(AgentResponse(clips: [clip]))
        #expect(String(decoding: line, as: UTF8.self).contains(#""started":"2027-01-15T08:00:00Z""#))
        #expect(try AgentWire.decoder.decode(AgentResponse.self, from: line).clips == [clip])
    }

    @Test func requestIDsAreSafeFolderNames() {
        for name in ["r1", "2026-10-17_a.b", String(repeating: "x", count: 64)] {
            #expect(AgentInbox.isValidName(name))
        }
        for name in ["", ".", "..", ".hidden", "a/b", "ä", String(repeating: "x", count: 65)] {
            #expect(!AgentInbox.isValidName(name), "\(name)")
        }
    }

    @Test func linesAreSplitAsTheyArrive() throws {
        var buffer = AgentLineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(buffer.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8), Data()])
        #expect(buffer.append(Data(repeating: UInt8(ascii: "x"), count: AgentProtocol.maxLineLength + 1)) == nil)
    }

    /// An upload's bytes come right after its line, newlines and all, and the next request after them.
    @Test func anUploadsBytesAreTakenRawBetweenLines() {
        var buffer = AgentLineBuffer()
        buffer.push(Data("{\"command\":\"upload\"}\nab\ncd{\"next\":1}".utf8))
        #expect(buffer.nextLine() == Data("{\"command\":\"upload\"}".utf8))
        #expect(buffer.take(upTo: 3) == Data("ab\n".utf8))
        #expect(buffer.take(upTo: 2) == Data("cd".utf8))
        #expect(buffer.nextLine() == nil, "the next line hasn't ended yet")
        buffer.push(Data("\n".utf8))
        #expect(buffer.nextLine() == Data("{\"next\":1}".utf8))
        #expect(buffer.take(upTo: 10).isEmpty && !buffer.isOverlong)
    }

    @Test func showTakesExactlyOneTarget() throws {
        let clip = try AgentWire.line(AgentRequest(.show(.clip("c1"))))
        #expect(String(decoding: clip, as: UTF8.self) == #"{"clip":"c1","command":"show","version":1}"# + "\n")
        for line in [
            #"{"version":1,"id":"1","command":"show"}"#,
            #"{"version":1,"id":"1","command":"show","screen":"jobs","clip":"c1"}"#,
            #"{"version":1,"id":"1","command":"show","screen":"trash"}"#,
        ] {
            let (id, request) = AgentWire.request(from: Data(line.utf8))
            #expect(id == "1")
            #expect(throws: AgentError.self) { try request.get() }
        }
    }

    @Test func aLibraryItemCutsItsPrompt() {
        func item(_ prompt: String) -> AgentLibraryItem {
            AgentLibraryItem(
                render: "r", clip: "c", title: "t", name: "Draft 1", quality: .draft, file: "/f.mp4", created: .now,
                finished: nil, duration: 5, prompt: prompt, draft: nil, finalizableUntil: nil, client: nil)
        }
        let short = item(String(repeating: "a", count: AgentLibraryItem.promptLength))
        #expect(!short.promptTruncated && short.prompt.count == AgentLibraryItem.promptLength)
        let long = item(String(repeating: "é", count: 1000))
        #expect(long.promptTruncated && long.prompt.count == AgentLibraryItem.promptLength && long.prompt.last == "…")
    }

    /// A `sockaddr_un` holds 103 bytes of path; the address is sized to the path instead, up to Darwin's 255 bytes.
    @Test func aSocketAddressIsSizedToItsPath() {
        let short = URL(filePath: "/tmp/agent.sock")
        let plain = AgentSocket.withAddress(short) { address, length in
            Int(length) == MemoryLayout<sockaddr_un>.size && Int(address.pointee.sa_len) == Int(length)
        }
        #expect(plain == true)
        let longest = URL(filePath: "/" + String(repeating: "x", count: AgentSocket.maxPathLength - 1))
        #expect(AgentSocket.fits(longest))
        let sized = AgentSocket.withAddress(longest) { address, length in
            Int(length) == 255 && address.pointee.sa_family == sa_family_t(AF_UNIX)
        }
        #expect(sized == true)
        let tooLong = URL(filePath: "/" + String(repeating: "x", count: AgentSocket.maxPathLength))
        #expect(!AgentSocket.fits(tooLong))
        #expect(AgentSocket.withAddress(tooLong) { _, _ in true } == nil)
        #expect(throws: AgentClient.Failure.pathTooLong) { try AgentClient(socket: tooLong) }
    }

    @Test func uploadedFileNamesAreOneVisibleComponent() {
        for name in ["clip.mov", "My clip (1).mov", "person-2.png", "ä.png", String(repeating: "x", count: 255)] {
            #expect(AgentInbox.isValidFileName(name))
        }
        for name in ["", ".partial", "a/b.mov", "../x", "a\u{0}b", String(repeating: "x", count: 256)] {
            #expect(!AgentInbox.isValidFileName(name), "\(name)")
        }
    }
}
