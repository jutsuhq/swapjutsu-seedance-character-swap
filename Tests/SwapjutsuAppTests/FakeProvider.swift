import Foundation

@testable import SwapjutsuApp

/// Answers `status` from a queue (pending once it runs out) and records submits and cancels.
final class FakeProvider: GenerationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Result<GenerationOutput, Error>]
    private let submitError: Error?
    private let cancels: Bool
    private var submitHook: (@Sendable () -> Void)?
    private var submitCount = 0
    private var cancelCalls: [String] = []
    private var sent: [GenerationRequest] = []

    /// Where a submit stops until it is canceled: in an upload before the paid request (which a cancel ends with
    /// `URLError.cancelled`, as URLSession does), or in the paid request itself.
    enum Hang { case upload, send }

    private let hang: Hang?
    private let sendsOnce: Bool

    /// `cancels: false` is a provider that can't cancel a started request, as the direct route. `sendsOnce` sends
    /// through `ComfySeedance.sendOnce`, as the real providers do; a `hang` implies it.
    init(
        statuses: [Result<GenerationOutput, Error>], submitError: Error? = nil, cancels: Bool = true,
        sendsOnce: Bool = false, hang: Hang? = nil
    ) {
        self.statuses = statuses
        self.submitError = submitError
        self.cancels = cancels
        self.sendsOnce = sendsOnce || hang != nil
        self.hang = hang
    }

    /// Runs as the provider takes a request, before it answers with the ID.
    var onSubmit: (@Sendable () -> Void)? {
        get { lock.withLock { submitHook } }
        set { lock.withLock { submitHook = newValue } }
    }

    /// Queues the next status answer.
    func answer(_ status: Result<GenerationOutput, Error>) { lock.withLock { statuses.append(status) } }

    var submits: Int { lock.withLock { submitCount } }
    var canceled: [String] { lock.withLock { cancelCalls } }
    var requests: [GenerationRequest] { lock.withLock { sent } }

    /// `submits` counts the paid requests: an upload that hangs never gets to one.
    func submit(_ request: GenerationRequest) async throws -> String {
        if hang == .upload {
            do { try await Task.sleep(for: .seconds(3600)) } catch { throw URLError(.cancelled) }
        }
        guard sendsOnce else { return try take(request) }
        return try await ComfySeedance.sendOnce {
            let id = try take(request)
            if hang == .send { try await Task.sleep(for: .seconds(3600)) }
            return id
        }
    }

    private func take(_ request: GenerationRequest) throws -> String {
        let count = lock.withLock {
            submitCount += 1
            sent.append(request)
            return submitCount
        }
        onSubmit?()
        if let submitError { throw submitError }
        return "r\(count)"
    }

    func status(of requestID: String) async throws -> GenerationStatus {
        let next = lock.withLock { statuses.isEmpty ? nil : statuses.removeFirst() }
        guard let next else { return .pending }
        return .completed(try next.get())
    }

    func cancel(_ requestID: String) async throws -> Bool {
        lock.withLock { cancelCalls.append(requestID) }
        return cancels
    }
}
