import Foundation
import SwapjutsuAgent

/// show and library_search: what an agent sees of Library is what the person sees, the finished drafts and finals in
/// the same order, and `show` opens the same pages a click does.
extension AgentCommands {
    func show(_ target: AgentShow) throws(AgentError) -> AgentResponse {
        let response: AgentResponse
        switch target {
        case .screen(let screen):
            navigation.screen = Screen(screen)
            response = AgentResponse(shown: screen)
        case .clip(let id):
            let job = try job(id)
            navigation.open(job.id)
            response = AgentResponse(shown: .create, clips: [clip(job)])
        case .result(let id):
            let (job, render) = try findRender(id)
            // Library lists only finished renders; any other opens where Create shows it.
            if render.stage == .done, job.resultURL(of: render) != nil {
                navigation.library(render.id)
                response = AgentResponse(shown: .library, renders: [renderInfo(render.id, of: job)].compactMap(\.self))
            } else {
                navigation.open(job.id, render: render.id)
                response = AgentResponse(shown: .create, renders: [renderInfo(render.id, of: job)].compactMap(\.self))
            }
        }
        bringForward()
        return response
    }

    /// Library's results, newest first, filtered and a page at a time. The cursor is the last result's render id, so a
    /// result finished meanwhile, which goes to the top, doesn't shift the pages after it.
    func librarySearch(_ command: LibrarySearchCommand) throws(AgentError) -> AgentResponse {
        let limit = command.limit ?? LibrarySearchCommand.defaultLimit
        guard (1...LibrarySearchCommand.maxLimit).contains(limit) else {
            throw .invalid("limit takes 1–\(LibrarySearchCommand.maxLimit) results a page.")
        }
        let words = (command.text ?? "").split(whereSeparator: \.isWhitespace)
        let matches = LibraryEntry.all(in: jobs.jobs).filter { entry in
            guard entry.url != nil else { return false }
            if let quality = command.quality, AgentQuality(entry.render.quality) != quality { return false }
            let text = [entry.job.title, entry.name, entry.render.prompt].joined(separator: "\n")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var start = matches.startIndex
        if let cursor = command.cursor {
            guard let index = matches.firstIndex(where: { $0.id.uuidString == cursor }) else {
                throw AgentError(
                    .badRequest, message: "The cursor \(cursor) is no longer among these results.", retryable: false,
                    next: "Search again without cursor.")
            }
            start = index + 1
        }
        let page = matches[start...].prefix(limit)
        let next = page.endIndex < matches.endIndex ? page.last?.id.uuidString : nil
        return AgentResponse(
            library: AgentLibraryPage(results: page.map(libraryItem), total: matches.count, nextCursor: next))
    }

    private func libraryItem(_ entry: LibraryEntry) -> AgentLibraryItem {
        let (job, render) = (entry.job, entry.render)
        return AgentLibraryItem(
            render: render.id.uuidString, clip: job.id.uuidString, title: job.title, name: entry.name,
            quality: AgentQuality(render.quality), file: entry.url?.path(percentEncoded: false) ?? "",
            created: render.created, finished: render.finished, duration: job.duration, prompt: render.prompt,
            draft: render.parent?.uuidString,
            finalizableUntil: render.canFinalize() && job.final(of: render) == nil ? render.finalizableUntil : nil,
            client: render.origin?.client)
    }
}
