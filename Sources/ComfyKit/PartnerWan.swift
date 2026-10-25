import Foundation

/// Wan 3.0 through the same Partner Nodes API, key and transport as Seedance, the way ComfyUI's
/// `Wan3ReferenceToVideoApi` calls it: the inputs go to Comfy's storage and the task names their public links.
extension PartnerSeedanceClient {
    static let wanCreatePath = "/proxy/wan/api/v1/services/aigc/video-generation/video-synthesis"
    static let wanTaskPath = "/proxy/wan/api/v1/tasks"

    /// `upload_image_to_comfyapi`: the same RGB PNG of at most 2048² pixels Seedance gets, so no transparency,
    /// which Wan refuses. Returns its public link.
    public func uploadWanImage(_ file: URL) async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Self.referencePNG(file).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await uploadToStorage(temporary, contentType: "image/png")
    }

    /// `upload_video_to_comfyapi`: the MP4 as prep wrote it. Returns its public link.
    public func uploadWanVideo(_ file: URL) async throws -> String {
        try await uploadToStorage(file, contentType: "video/mp4")
    }

    /// Creates the task and returns its ID. A reply without `output` is Wan's refusal.
    public func createWanTask(_ request: WanTaskRequest) async throws -> String {
        let created: WanCreatedTask = try await call("POST", Self.wanCreatePath, body: try Self.encode(request))
        guard let id = created.output?.taskID else {
            let reason = [created.code, created.message].compactMap { $0 }.joined(separator: ": ")
            throw ComfyError.rejected(status: 200, code: created.code, message: reason.isEmpty ? "No task" : reason)
        }
        return id
    }

    /// `GET /proxy/wan/api/v1/tasks/{id}`.
    public func wanTask(_ id: String) async throws -> WanTask {
        try await call("GET", "\(Self.wanTaskPath)/\(id)")
    }
}
