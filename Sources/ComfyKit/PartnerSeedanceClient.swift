import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Seedance through Comfy's Partner Nodes API (`api.comfy.org`), the way ComfyUI's own `ByteDance2ReferenceNodeV2`
/// and `ByteDance2DraftToFinalVideoNode` call it, billed from the account's prepaid credits with no subscription.
///
/// Replicates `comfy_api_nodes/nodes_bytedance.py`, `util/client.py`, `util/_helpers.py` and
/// `util/upload_helpers.py` at ComfyUI commit 5cc4b870094c89090db54bd8d12649dcaf89f2ba (version 0.41.0): the
/// headers, the upload into Seedance's virtual library, task creation, polling and the retry rules of `sync_op`.
public struct PartnerSeedanceClient: Sendable {
    public static let api: URL = {
        guard let url = URL(string: "https://api.comfy.org") else { preconditionFailure("Invalid Comfy API URL") }
        return url
    }()

    /// `comfyui_version.__version__` of the source this client follows; the proxy may key behavior on it.
    public static let coreVersion = "0.41.0"
    /// `Comfy-Env` and `Comfy-Usage-Source`: ComfyUI sends its install kind and the submitting client, both
    /// free-form; this app names itself.
    public static let environment = "swapjutsu"
    public static let usageSource = "swapjutsu"

    static let createTaskPath = "/proxy/byteplus/api/v3/contents/generations/tasks"
    /// The node creates on `/proxy/byteplus/…` and polls on `/proxy/byteplus-seedance2/…`.
    static let taskStatusPath = "/proxy/byteplus-seedance2/api/v3/contents/generations/tasks"
    /// `upload_image_to_comfyapi`'s default `total_pixels`.
    static let maxImagePixels = 2048 * 2048

    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession
    public let retry: PartnerRetryPolicy
    public let sleep: Sleeper

    public init(
        apiKey: String, baseURL: URL = api, session: URLSession = .shared, retry: PartnerRetryPolicy = .init(),
        sleep: @escaping Sleeper = taskSleep
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    // MARK: Seedance

    /// `_seedance_virtual_library_upload_image_asset`: an RGB PNG of at most 2048² pixels into storage, then into
    /// the caller's Seedance virtual library. Returns the `asset://<id>` the task references.
    public func uploadReferenceImage(_ file: URL) async throws -> String {
        let png = try Self.referencePNG(file)
        let temporary = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try png.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = try await uploadToStorage(temporary, contentType: "image/png")
        return try await libraryAsset(url: url, hash: Self.hex(SHA256.hash(data: png)), type: nil)
    }

    /// `_seedance_virtual_library_upload_video_asset`: the MP4 as it is (prep already writes H.264 MP4), keyed by
    /// the SHA-256 of its bytes.
    public func uploadReferenceVideo(_ file: URL) async throws -> String {
        let hash = try Self.sha256(of: file)
        let url = try await uploadToStorage(file, contentType: "video/mp4")
        return try await libraryAsset(url: url, hash: hash, type: "Video")
    }

    /// `POST /proxy/byteplus/api/v3/contents/generations/tasks` → the task ID, which is also a draft's
    /// `draft_task_id`.
    public func createTask(_ request: SeedanceTaskRequest) async throws -> String {
        let created: CreatedTask = try await call("POST", Self.createTaskPath, body: try Self.encode(request))
        return created.id
    }

    /// `GET /proxy/byteplus-seedance2/api/v3/contents/generations/tasks/{id}`.
    public func task(_ id: String) async throws -> SeedanceTask {
        try await call("GET", "\(Self.taskStatusPath)/\(id)")
    }

    /// `GET /proxy/seedance/assets/{id}`.
    public func asset(_ id: String) async throws -> SeedanceAsset {
        try await call("GET", "/proxy/seedance/assets/\(id)")
    }

    // MARK: Uploads

    /// `upload_file_to_comfyapi`: a signed slot from `POST /customers/storage`, a `PUT` of the bytes to it, and the
    /// slot's public `download_url`.
    func uploadToStorage(_ file: URL, contentType: String) async throws -> String {
        let name = "\(UUID().uuidString.lowercased()).\(file.pathExtension.lowercased())"
        let slot: StorageUpload = try await call(
            "POST", "/customers/storage", body: try Self.encode(["file_name": name, "content_type": contentType]))
        guard let target = URL(string: slot.uploadURL) else {
            throw ComfyError.malformedResponse("Comfy returned an unusable upload link.")
        }
        try await put(file, to: target, contentType: contentType)
        return slot.downloadURL
    }

    /// `POST /proxy/seedance/virtual-library/assets`, then `_wait_for_asset_active`.
    private func libraryAsset(url: String, hash: String, type: String?) async throws -> String {
        let created: CreatedAsset = try await call(
            "POST", "/proxy/seedance/virtual-library/assets",
            body: try Self.encode(LibraryAssetRequest(url: url, hash: hash, assetType: type)))
        try await waitUntilActive(created.assetID)
        return "asset://\(created.assetID)"
    }

    /// Polls the asset every 5 s until `Active`; `Failed` ends it.
    func waitUntilActive(_ id: String) async throws {
        for _ in 0..<retry.assetMaxPolls {
            let asset = try await asset(id)
            switch asset.status.lowercased() {
            case "active": return
            case "failed":
                let reason = asset.error.map { "\($0.code): \($0.message)" } ?? "status Failed"
                throw ComfyError.jobFailed(
                    .init(
                        code: asset.error?.code, message: "Seedance could not take the upload (\(reason)).",
                        nodeId: nil, classType: nil))
            default: try await sleep(retry.assetPollInterval)
            }
        }
        throw ComfyError.malformedResponse("Seedance did not finish processing the upload \(id).")
    }

    /// `upload_file`: no Comfy headers on the signed URL; 408, 429 and 5xx and dropped connections are retried.
    private func put(_ file: URL, to target: URL, contentType: String) async throws {
        var request = URLRequest(url: target, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        var (attempt, delay) = (0, retry.retryDelay)
        while true {
            attempt += 1
            do {
                let (_, response) = try await session.upload(for: request, fromFile: file)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status < 400 { return }
                guard [408, 429, 500, 502, 503, 504].contains(status), attempt <= retry.maxRetries else {
                    throw ComfyError.rejected(status: status, code: nil, message: "Failed to upload (HTTP \(status)).")
                }
            } catch let error as URLError where error.code != .cancelled && attempt <= retry.maxRetries {}
            try await sleep(delay)
            delay *= retry.backoff
        }
    }

    // MARK: Transport

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: method == "GET" ? 120 : 600)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// `get_comfy_api_headers` with an API key, plus `Accept`.
    var headers: [String: String] {
        [
            "Accept": "application/json", "X-API-KEY": apiKey, "Comfy-Env": Self.environment,
            "Comfy-Usage-Source": Self.usageSource, "Comfy-Core-Version": Self.coreVersion,
        ]
    }

    /// `_request_base`: a POST carries one `Idempotency-Key` (`uuid4().hex`) on every attempt. 408 and 5xx are
    /// retried `maxRetries` times, 429 `maxRateLimitRetries` times, a `409 idempotency_in_flight` is waited out,
    /// dropped connections are retried; a `Retry-After` replaces the backoff and is waited in full. One longer than
    /// `maxRetryAfter` gives the refusal back at once instead of asking early, except for an in-flight create, which
    /// may still become a task. A GET uses the per-poll budget (`max_retries_per_poll`) instead.

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        var request = try request(method, path)
        var key = method == "GET" ? nil : Self.idempotencyKey()
        var budget = RetryBudget(policy: retry, isGet: method == "GET")
        while true {
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
            let wait: TimeInterval
            do {
                let (data, response) =
                    if let body { try await session.upload(for: request, from: body) } else {
                        try await session.data(for: request)
                    }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if (200..<300).contains(status) { return try Self.decode(T.self, data) }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let errorType =
                    (http?.value(forHTTPHeaderField: "X-Comfy-Error-Type") ?? json?["error_type"] as? String ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(ComfyClient.retryAfter)
                if key != nil, status == 409, ["idempotency_consumed", "idempotency_mismatch"].contains(errorType) {
                    throw ComfyError.idempotencyKeyReuse(Self.message(status: status, json: json, data: data))
                }
                let inFlight = key != nil && status == 409 && errorType == "idempotency_in_flight"
                let disabled = json?["error"] as? String == "comfy_cloud_provider_disabled"
                if let retryAfter, retryAfter > retry.maxRetryAfter, !inFlight {
                    throw Self.error(status: status, body: data, retryAfter: retryAfter)
                }
                guard
                    let next = budget.wait(
                        status: status, inFlight: inFlight, disabled: disabled, retryAfter: retryAfter)
                else {
                    // Waited out: the server still has the create in flight, which may yet become a task.
                    if inFlight {
                        throw ComfyError.rejected(
                            status: status, code: ComfyError.inFlight,
                            message: Self.message(status: status, json: json, data: data))
                    }
                    throw Self.error(status: status, body: data, retryAfter: retryAfter)
                }
                // A replayed refusal means the server holds that key's answer. Only a rate limit is sure to have
                // created nothing, so only it is asked again under a fresh key; a replayed 5xx may stand for a task
                // the server made before it failed, and a new key could pay for a second one.
                if key != nil, !inFlight, http?.value(forHTTPHeaderField: "Idempotent-Replayed") != nil {
                    guard status == 429 else { throw Self.error(status: status, body: data, retryAfter: retryAfter) }
                    key = Self.idempotencyKey()
                }
                wait = next
            } catch let error as URLError {
                guard error.code != .cancelled, let next = budget.connectionWait() else { throw error }
                wait = next
            }
            try await sleep(wait)
        }
    }

    static func idempotencyKey() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw ComfyError.malformedResponse("\(T.self): \(error.localizedDescription)")
        }
    }

}

extension PartnerSeedanceClient {
    // MARK: Errors

    /// The refusal as the app acts on it: a key problem, no credits, busy, or the proxy's own message.
    static func error(status: Int, body: Data, retryAfter: TimeInterval?) -> ComfyError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = message(status: status, json: json, data: body)
        let code = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["code"] as? String
        switch status {
        case 401, 403: return .unauthorized(message)
        case 402: return .insufficientCredits(message)
        case 429: return .busy(code: code ?? "rate_limited", message: message, retryAfter: retryAfter)
        case 404: return .notFound(message)
        default: return .rejected(status: status, code: code, message: message)
        }
    }

    /// `_friendly_http_message`, preferring the proxy's own words where the node prints a fixed line.
    static func message(status: Int, json: [String: Any]?, data: Data) -> String {
        if let detail = json.flatMap(detail) { return status == 402 ? "\(detail) \(billing)" : detail }
        switch status {
        case 401, 403: return "Check the key in Settings › Comfy."
        case 402: return "Payment required. \(billing)"
        case 409: return "There is a problem with your account. Please contact support@comfy.org."
        case 429: return "Rate limit exceeded. Please wait and try again."
        default:
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            return text.isEmpty ? "HTTP \(status)" : text
        }
    }

    static let billing = "Add credits at platform.comfy.org/profile/billing."

    /// The readable part of `{"error": code, "message"}`, `{"error": {"message", "type", "metadata"}}`, or
    /// `{"detail"}` / `{"message"}`.
    private static func detail(_ body: [String: Any]) -> String? {
        if body["error_type"] as? String == "service_unavailable" {
            return "The API server could not verify this request right now. Please try again in a moment."
        }
        if body["error"] is String, let message = body["message"] as? String, !message.isEmpty { return message }
        if let error = body["error"] as? [String: Any] {
            let message = (error["message"]).map { "\($0)" }
            let provider = providerDetail(error["metadata"])
            let text =
                switch (message, provider) {
                case (let message?, let provider?) where !message.contains(provider): "\(message): \(provider)"
                case (let message?, _): message
                case (nil, let provider): provider
                }
            if let text, let type = error["type"] as? String { return "\(text) (\(type))" }
            if let text { return text }
        }
        for key in ["detail", "message"] {
            if let text = body[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// `_provider_error_detail`: the upstream provider's message inside `metadata.raw`, or its error code.
    private static func providerDetail(_ metadata: Any?) -> String? {
        guard let metadata = metadata as? [String: Any] else { return nil }
        if let raw = (metadata["raw"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            if let inner = (parsed?["error"] as? [String: Any])?["message"] as? String { return inner }
            if let message = parsed?["message"] as? String { return message }
            return String(raw.prefix(500))
        }
        return (metadata["provider_error_code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Files

    /// `_compute_downscale_dims`: even sides that fit `total`, or nil when the image already fits.
    static func downscaledSize(width: Int, height: Int, total: Int) -> (width: Int, height: Int)? {
        guard width * height > total else { return nil }
        let scale = (Double(total) / Double(width * height)).squareRoot()
        let (long, short) = (max(width, height), min(width, height))
        func shortSide(_ long2: Int) -> Int {
            max(2, Int((Double(long2) * Double(short) / Double(long) / 2).rounded(.up)) * 2)
        }
        var newLong = max(2, Int(Double(long) * scale) / 2 * 2)
        var newShort = shortSide(newLong)
        if newLong * newShort > total {
            newLong = max(2, total / newShort / 2 * 2)
            newShort = shortSide(newLong)
        }
        return width >= height ? (newLong, newShort) : (newShort, newLong)
    }

    /// The image as `LoadImage` + `tensor_to_bytesio` hand it on: EXIF orientation applied, alpha dropped, at most
    /// 2048² pixels, PNG.
    static func referencePNG(_ file: URL) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 100_000,
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: file]) }
        let size =
            downscaledSize(width: image.width, height: image.height, total: maxImagePixels)
            ?? (image.width, image.height)
        let data = NSMutableData()
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let flat = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, flat, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
