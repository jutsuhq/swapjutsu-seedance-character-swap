import ComfyKit
import Foundation
import SwapjutsuAgent

/// The MCP tools, one per app command. Arguments are snake_case, as MCP tools usually are; the app's answer keeps its
/// own camelCase JSON.
enum Tool: String, CaseIterable {
    case capabilities, show, prepare, clips
    case setCharacters = "set_characters"
    case prepareAgain = "prepare_again"
    case quote, render, finalize
    case jobAction = "job_action"
    case librarySearch = "library_search"
    case correctTarget = "correct_target"

    /// What a call needs besides its arguments.
    struct Context {
        /// `clientInfo.name` from initialize.
        var client: String?
        var stage: MCPServer.Stage
    }

    /// Why a call never reached the app: a JSON-RPC error for a tool that has always had one (`show`), a tool error
    /// the model reads and can correct for the others.
    enum Failure: Error {
        case invalid(String)
        case refused(AgentError)
    }

    func command(_ arguments: [String: JSONValue], _ context: Context) async -> Result<AgentCommand, Failure> {
        do throws(Failure) {
            return .success(try await make(arguments, context))
        } catch {
            return .failure(error)
        }
    }

    private func make(_ arguments: [String: JSONValue], _ context: Context) async throws(Failure) -> AgentCommand {
        switch self {
        case .capabilities:
            return .capabilities
        case .show:
            return .show(try show(arguments))
        case .prepare:
            return try await prepare(try decode(PrepareArguments.self, arguments), context)
        case .clips:
            let given = try decode(ClipsArguments.self, arguments)
            return .clips(ClipsCommand(clip: given.clip, waitSeconds: given.waitSeconds))
        case .setCharacters:
            return try await setCharacters(try decode(SetCharactersArguments.self, arguments), context)
        case .prepareAgain:
            let given = try decode(PrepareAgainArguments.self, arguments)
            return .prepareAgain(
                PrepareAgainCommand(
                    clip: given.clip, target: given.target, faceGuide: given.faceGuide, control: given.control))
        case .correctTarget:
            let given = try decode(CorrectTargetArguments.self, arguments)
            var file: String?
            if let mask = given.mask { file = try await stage(mask, as: "mask", into: UUID().uuidString, context) }
            return .correctTarget(
                CorrectTargetCommand(
                    clip: given.clip, person: given.person, frame: given.frame, x: given.x, y: given.y,
                    mask: given.mask, file: file))
        case .quote:
            let given = try decode(QuoteArguments.self, arguments)
            return .quote(QuoteCommand(clip: given.clip, quality: given.quality, model: given.model))
        case .render:
            let given = try decode(RenderArguments.self, arguments)
            return .render(
                RenderCommand(
                    clip: given.clip, quality: given.quality, requestID: given.requestId, maxCost: given.maxCost,
                    client: context.client, model: given.model))
        case .finalize:
            let given = try decode(FinalizeArguments.self, arguments)
            return .finalize(
                FinalizeCommand(
                    render: given.render, requestID: given.requestId, maxCost: given.maxCost, client: context.client))
        case .jobAction:
            let given = try decode(JobActionArguments.self, arguments)
            return .jobAction(JobActionCommand(job: given.job, action: given.action))
        case .librarySearch:
            let given = try decode(LibrarySearchArguments.self, arguments)
            return .librarySearch(
                LibrarySearchCommand(text: given.text, quality: given.quality, limit: given.limit, cursor: given.cursor)
            )
        }
    }

    /// Exactly one of screen, clip or result.
    private func show(_ arguments: [String: JSONValue]) throws(Failure) -> AgentShow {
        let names = AgentScreen.allCases.map(\.rawValue).joined(separator: ", ")
        switch (arguments["screen"]?.string, arguments["clip"]?.string, arguments["result"]?.string) {
        case (let screen?, nil, nil):
            guard let screen = AgentScreen(rawValue: screen) else { throw .invalid("show: screen is one of \(names).") }
            return .screen(screen)
        case (nil, let clip?, nil): return .clip(clip)
        case (nil, nil, let result?): return .result(result)
        default: throw .invalid("show needs one of screen (\(names)), clip (a clip id) or result (a render id).")
        }
    }

    private func prepare(_ given: PrepareArguments, _ context: Context) async throws(Failure) -> AgentCommand {
        // Checked before anything is sent; the app refuses it anyway.
        guard AgentInbox.isValidName(given.requestId) else {
            throw .refused(.badRequest("request_id takes 1–64 letters, digits, '.', '_' or '-', not starting with '.'"))
        }
        // A folder of its own per call, not per request_id: a repeated id the app then refuses must not replace the
        // video a clip still waiting for prep reads from the inbox. An unused copy goes with the inbox sweep.
        let file = try await stage(given.video, as: nil, into: UUID().uuidString, context)
        return .prepare(
            PrepareCommand(
                requestID: given.requestId, video: given.video, file: file, ranges: given.ranges, target: given.target,
                faceGuide: given.faceGuide, control: given.control, client: context.client))
    }

    private func setCharacters(
        _ given: SetCharactersArguments, _ context: Context
    ) async throws(Failure) -> AgentCommand {
        let folder = UUID().uuidString
        var characters: [SetCharactersCommand.Character]?
        if let given = given.characters {
            characters = []
            for (n, character) in given.enumerated() {
                let name = "person-\(character.person)" + (character.view == true ? "-view-\(n + 1)" : "")
                let file = try await stage(character.image, as: name, into: folder, context)
                characters?.append(
                    .init(person: character.person, image: character.image, file: file, view: character.view))
            }
        }
        return .setCharacters(
            SetCharactersCommand(
                clip: given.clip, characters: characters, removeBackground: given.removeBackground,
                prompt: given.prompt))
    }

    /// The arguments read as `type`, snake_case keys and all; a missing or mistyped one is named.
    private func decode<T: Decodable>(_ type: T.Type, _ arguments: [String: JSONValue]) throws(Failure) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: JSONEncoder().encode(JSONValue.object(arguments)))
        } catch DecodingError.keyNotFound(let key, _) {
            throw .refused(.badRequest("\(rawValue) needs \(Self.snakeCase(key.stringValue))."))
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
            DecodingError.dataCorrupted(let context)
        {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? Self.snakeCase($0.stringValue) }
            throw .refused(.badRequest("\(rawValue): \(path.joined(separator: ".")) has the wrong type."))
        } catch {
            throw .refused(.badRequest("\(rawValue): \(error.localizedDescription)"))
        }
    }

    private func stage(
        _ path: String, as name: String?, into folder: String, _ context: Context
    ) async throws(Failure) -> String {
        do throws(AgentError) {
            return try await context.stage(path, name, folder).path(percentEncoded: false)
        } catch {
            throw .refused(error)
        }
    }

    private static func snakeCase(_ key: String) -> String {
        key.reduce(into: "") { $0 += $1.isUppercase ? "_" + $1.lowercased() : String($1) }
    }
}

// The tools' arguments as they come, snake_case read as camelCase. Left out means "as it is" (Settings › Prep, or
// what the clip has), which false can't say.
// swiftlint:disable discouraged_optional_boolean

private struct PrepareArguments: Decodable {
    var video: String
    var requestId: String
    var ranges: [AgentRange]?
    var target: AgentTarget?
    var faceGuide: Bool?
    var control: AgentControl?
}

private struct ClipsArguments: Decodable {
    var clip: String?
    var waitSeconds: Double?
}

private struct CharacterArguments: Decodable {
    var person: Int
    var image: String
    var view: Bool?
}

private struct SetCharactersArguments: Decodable {
    var clip: String
    var characters: [CharacterArguments]?
    var removeBackground: Bool?
    var prompt: String?
}

private struct PrepareAgainArguments: Decodable {
    var clip: String
    var target: AgentTarget?
    var faceGuide: Bool?
    var control: AgentControl?
}

// swiftlint:enable discouraged_optional_boolean

private struct CorrectTargetArguments: Decodable {
    var clip: String
    var person: Int?
    var frame: Int
    var x: Double?
    var y: Double?
    var mask: String?
}

private struct QuoteArguments: Decodable {
    var clip: String
    var quality: AgentQuality
    var model: AgentModel?
}

private struct RenderArguments: Decodable {
    var clip: String
    var quality: AgentQuality
    var requestId: String
    var maxCost: Double
    var model: AgentModel?
}

private struct FinalizeArguments: Decodable {
    var render: String
    var requestId: String
    var maxCost: Double
}

private struct JobActionArguments: Decodable {
    var job: String
    var action: AgentJobAction
}

private struct LibrarySearchArguments: Decodable {
    var text: String?
    var quality: AgentQuality?
    var limit: Int?
    var cursor: String?
}
