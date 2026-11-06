import Foundation
import Synchronization
import Observation
import Photos

// MARK: - PHAsset Identifier Store

/// Persists a mapping of server assetId → PHAsset.localIdentifier so re-upload can find the original video.
enum PHAssetIdentifierStore {
    private static let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("phasset-identifiers.json")
    }()
    
    static func save(assetId: String, phAssetIdentifier: String) {
        var map = loadAll()
        map[assetId] = phAssetIdentifier
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
    
    static func identifier(for assetId: String) -> String? {
        loadAll()[assetId]
    }
    
    static func remove(assetId: String) {
        var map = loadAll()
        map.removeValue(forKey: assetId)
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
    
    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }
}

// MARK: - Persisted Form State

/// Saved to disk so the app can restore the context form after crash/kill.
struct PendingForm: Codable {
    let assetId: String
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    let thumbnailJPEG: Data?  // JPEG-encoded thumbnail
    let savedAt: Date
    
    static let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pending-form.json")
    }()
    
    static func save(_ form: PendingForm) {
        do {
            let data = try JSONEncoder().encode(form)
            try data.write(to: storageURL, options: .atomic)
            print("💾 [Form] Saved pending form state for asset: \(form.assetId)")
        } catch {
            print("⚠️ [Form] Failed to save pending form state: \(error)")
        }
    }
    
    static func load() -> PendingForm? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode(PendingForm.self, from: data)
        } catch {
            print("⚠️ [Form] Failed to load pending form state: \(error)")
            clear()
            return nil
        }
    }
    
    static func clear() {
        try? FileManager.default.removeItem(at: storageURL)
        print("🗑️ [Form] Cleared pending form state")
    }
}

/// Handles multipart video file uploads with progress tracking.
@MainActor
@Observable
final class VideoUploadService: NSObject {
    // MARK: - State
    
    var uploadProgress: Double = 0
    var isUploading = false
    var error: String?
    
    // MARK: - Private
    
    // MARK: - Mux Direct Upload
    
    /// Upload via Mux direct upload: ask server for a Mux upload URL, then PUT file directly to Mux CDN.
    /// This bypasses the server for the large file transfer — only metadata goes through the server.
    func uploadViaMux(assetId: String, fileURL: URL, token: String, metadata: VideoMetadata? = nil) async throws -> MuxUploadResponse {
        isUploading = true
        uploadProgress = 0
        error = nil
        defer { isUploading = false }
        
        print("📤 [Mux] Requesting direct upload URL for asset: \(assetId)")
        
        // Step 1: Ask server for a Mux direct upload URL (fast — just metadata)
        let muxURL = ServerConfig.muxUploadURL(assetId)
        var createRequest = URLRequest(url: muxURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Send metadata + file info as JSON
        // Get file size once — used for both metadata payload and Content-Length header
        let fileSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 { return size }
            return 0
        }()

        var metaDict: [String: Any] = [:]
        if let meta = metadata {
            metaDict = [
                "fileName": fileURL.lastPathComponent,
                "duration": meta.duration,
                "resolution": meta.resolution,
                "codec": meta.codec,
                "orientation": meta.orientation,
                "deviceModel": meta.deviceModel,
                "osVersion": meta.osVersion,
            ]
            if let capturedAt = meta.capturedAt { metaDict["capturedAt"] = capturedAt }
            if let lat = meta.gpsLat { metaDict["gpsLat"] = lat }
            if let lon = meta.gpsLon { metaDict["gpsLon"] = lon }
            if let alt = meta.gpsAltitude { metaDict["gpsAltitude"] = alt }
            if fileSize > 0 { metaDict["fileSize"] = fileSize }
        }
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: ["metadata": metaDict])
        
        let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
        
        guard let httpResp = createResponse as? HTTPURLResponse, httpResp.statusCode == 200 else {
            let body = String(data: createData, encoding: .utf8) ?? "Unknown"
            print("📤 [Mux] ❌ Failed to get upload URL: \(body)")
            throw UploadError.serverError((createResponse as? HTTPURLResponse)?.statusCode ?? 0, body)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let uploadUrlString = json["uploadUrl"] as? String,
              let uploadUrl = URL(string: uploadUrlString),
              let clipId = json["clipId"] as? String else {
            throw UploadError.invalidResponse
        }
        
        print("📤 [Mux] Got upload URL, uploading directly to Mux CDN...")
        
        // Simple PUT to Mux direct upload URL (no tus headers needed)
        var putRequest = URLRequest(url: uploadUrl)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if fileSize > 0 {
            putRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        }
        
        let (_, putResponse) = try await uploadWithProgress(request: putRequest, fileURL: fileURL)
        
        guard let putHttp = putResponse as? HTTPURLResponse,
              (200...204).contains(putHttp.statusCode) else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            print("📤 [Mux] ❌ PUT to Mux failed with status \(code)")
            throw UploadError.serverError(code, "Mux upload failed")
        }
        
        uploadProgress = 1.0
        print("📤 [Mux] ✅ Direct upload complete! Mux will process and notify via webhook.")
        
        return MuxUploadResponse(clipId: clipId, muxUploadId: json["muxUploadId"] as? String ?? "")
    }
    
    // MARK: - Upload with Progress (Background session + waitsForConnectivity)
    
    private func uploadWithProgress(request: URLRequest, fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = UploadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.uploadProgress = progress
                    }
                },
                onComplete: { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: UploadError.invalidResponse)
                    }
                }
            )
            
            // Background session — upload continues when app is suspended by iOS.
            // waitsForConnectivity — pauses on network blip instead of failing (A4).
            let config = URLSessionConfiguration.background(
                withIdentifier: "com.directvideo.upload.\(UUID().uuidString)"
            )
            config.isDiscretionary = false          // Upload immediately, don't defer
            config.sessionSendsLaunchEvents = true  // Re-launch app to handle completion
            config.waitsForConnectivity = true      // Pause on network loss instead of failing
            config.timeoutIntervalForResource = 600 // 10 min max for large videos
            
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.resume()
        }
    }
    
}

// MARK: - Upload Delegate (Progress Tracking)

/// URLSession calls the delegate on its own serial queue; the response buffer is still
/// behind a `Mutex` so the class is checked `Sendable`.
private final class UploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    
    private let responseData = Mutex(Data())
    
    init(onProgress: @escaping @Sendable (Double) -> Void, onComplete: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.withLock { $0.append(data) }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(responseData.withLock { $0 }, task.response, nil)
        }
    }
    
    // Background session requires handling this to allow the session to reconnect
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        print("⏳ [Upload] Waiting for connectivity — upload will resume when network returns")
    }
}

// MARK: - Mux Upload Response

struct MuxUploadResponse {
    let clipId: String
    let muxUploadId: String
}

// MARK: - Errors

enum UploadError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .serverError(let code, let msg): return "Upload failed (HTTP \(code)): \(msg)"
        case .fileNotFound: return "Video file not found"
        }
    }
}
