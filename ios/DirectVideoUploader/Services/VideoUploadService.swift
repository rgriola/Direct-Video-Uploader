import Foundation
import Observation

// MARK: - Persisted Upload State (B3)

/// Saved to disk so the app can detect and reconcile incomplete uploads after crash/kill.
struct PendingUpload: Codable {
    let assetId: String
    let fileName: String
    let fileURL: String        // Absolute path to the temp multipart body or original file
    let startedAt: Date
    var method: String = "server" // "server" or "mux"
    var uploadUrl: String?     // Mux upload URL for tus resume (C3)
    var totalFileSize: Int64?  // Total file size for resume progress calculation
    
    static let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("pending-upload.json")
    }()
    
    static func save(_ upload: PendingUpload) {
        do {
            let data = try JSONEncoder().encode(upload)
            try data.write(to: storageURL, options: .atomic)
            print("💾 [Upload] Saved pending upload state for asset: \(upload.assetId)")
        } catch {
            print("⚠️ [Upload] Failed to save pending upload state: \(error)")
        }
    }
    
    static func load() -> PendingUpload? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode(PendingUpload.self, from: data)
        } catch {
            print("⚠️ [Upload] Failed to load pending upload state: \(error)")
            clear()
            return nil
        }
    }
    
    static func clear() {
        try? FileManager.default.removeItem(at: storageURL)
        print("🗑️ [Upload] Cleared pending upload state")
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
    
    private var continuation: CheckedContinuation<Data, Error>?
    private var progressContinuation: AsyncStream<Double>.Continuation?
    
    // MARK: - Upload
    
    /// Upload a video file to the server as multipart/form-data.
    /// Returns the raw response data from the server.
    func upload(assetId: String, fileURL: URL, token: String, metadata: VideoMetadata? = nil) async throws -> Data {
        isUploading = true
        uploadProgress = 0
        error = nil
        defer { isUploading = false }
        
        let url = ServerConfig.uploadURL(assetId)
        print("📤 [Upload] Starting upload to: \(url.absoluteString)")
        print("📤 [Upload] File: \(fileURL.lastPathComponent)")
        
        // Build multipart body
        let boundary = "Boundary-\(UUID().uuidString)"
        let (bodyURL, bodySize) = try buildMultipartFile(fileURL: fileURL, boundary: boundary, metadata: metadata)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(bodySize)", forHTTPHeaderField: "Content-Length")
        
        // B3: Persist upload state before starting
        PendingUpload.save(PendingUpload(
            assetId: assetId,
            fileName: fileURL.lastPathComponent,
            fileURL: fileURL.absoluteString,
            startedAt: Date(),
            method: "server"
        ))
        
        // Use delegate-based upload for progress tracking
        let (data, response) = try await uploadWithProgress(request: request, fileURL: bodyURL)
        
        // Clean up temp multipart body file
        try? FileManager.default.removeItem(at: bodyURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        
        print("📤 [Upload] HTTP status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("📤 [Upload] ❌ Error: \(body)")
            throw UploadError.serverError(httpResponse.statusCode, body)
        }
        
        uploadProgress = 1.0
        PendingUpload.clear() // B3: Upload succeeded — remove persisted state
        print("📤 [Upload] ✅ Upload complete!")
        return data
    }
    
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
            
            // File size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                metaDict["fileSize"] = size
            }
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
        
        // B3: Persist upload state before starting Mux upload (with tus URL for resume)
        let fileSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 { return size }
            return 0
        }()
        PendingUpload.save(PendingUpload(
            assetId: assetId,
            fileName: fileURL.lastPathComponent,
            fileURL: fileURL.absoluteString,
            startedAt: Date(),
            method: "mux",
            uploadUrl: uploadUrlString,
            totalFileSize: fileSize
        ))
        
        // Step 2: Upload file to Mux using tus protocol (PATCH with offset 0)
        var patchRequest = URLRequest(url: uploadUrl)
        patchRequest.httpMethod = "PATCH"
        patchRequest.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        patchRequest.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        patchRequest.setValue("0", forHTTPHeaderField: "Upload-Offset")
        if fileSize > 0 {
            patchRequest.setValue("\(fileSize)", forHTTPHeaderField: "Upload-Length")
            patchRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        }
        
        let (_, putResponse) = try await uploadWithProgress(request: patchRequest, fileURL: fileURL)
        
        guard let putHttp = putResponse as? HTTPURLResponse,
              (200...204).contains(putHttp.statusCode) else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            print("📤 [Mux] ❌ PUT to Mux failed with status \(code)")
            throw UploadError.serverError(code, "Mux upload failed")
        }
        
        uploadProgress = 1.0
        PendingUpload.clear() // B3: Mux upload succeeded — remove persisted state
        print("📤 [Mux] ✅ Direct upload complete! Mux will process and notify via webhook.")
        
        return MuxUploadResponse(clipId: clipId, muxUploadId: json["muxUploadId"] as? String ?? "")
    }
    
    // MARK: - Multipart Body Builder
    
    /// Writes multipart form data to a temp file (avoids loading entire video into memory).
    private func buildMultipartFile(fileURL: URL, boundary: String, metadata: VideoMetadata? = nil) throws -> (URL, Int64) {
        let fileName = fileURL.lastPathComponent
        let mimeType = "video/quicktime"
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        
        // Metadata fields (if provided)
        if let meta = metadata {
            let fields: [(String, String)] = [
                ("duration", "\(meta.duration)"),
                ("resolution", meta.resolution),
                ("codec", meta.codec),
                ("orientation", meta.orientation),
                ("deviceModel", meta.deviceModel),
                ("osVersion", meta.osVersion),
                ("capturedAt", meta.capturedAt ?? ""),
                ("gpsLat", meta.gpsLat.map { "\($0)" } ?? ""),
                ("gpsLon", meta.gpsLon.map { "\($0)" } ?? ""),
                ("gpsAltitude", meta.gpsAltitude.map { "\($0)" } ?? ""),
            ]
            for (name, value) in fields where !value.isEmpty {
                let part = "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                    + "\(value)\r\n"
                handle.write(part.data(using: .utf8)!)
            }
        }
        
        // File header
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        handle.write(header.data(using: .utf8)!)
        
        // Video data (stream from file to avoid loading into memory)
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        let chunkSize = 1024 * 1024 // 1 MB chunks
        while autoreleasepool(invoking: {
            let chunk = readHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            handle.write(chunk)
            return true
        }) {}
        readHandle.closeFile()
        
        // Footer
        let footer = "\r\n--\(boundary)--\r\n"
        handle.write(footer.data(using: .utf8)!)
        handle.closeFile()
        
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = attrs[.size] as? Int64 ?? 0
        
        print("📤 [Upload] Multipart body size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        
        return (tempURL, size)
    }
    
    // MARK: - Upload with Progress (A3: Background session + A4: waitsForConnectivity)
    
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
    
    // MARK: - Tus Resumable Upload (C3)
    
    /// Check the current upload offset via tus HEAD request.
    /// Returns the number of bytes Mux has already received, or 0 if the upload hasn't started.
    func checkTusOffset(uploadUrl: URL) async throws -> Int64 {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "HEAD"
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResp = response as? HTTPURLResponse,
              (200...204).contains(httpResp.statusCode) else {
            return 0
        }
        
        if let offsetStr = httpResp.value(forHTTPHeaderField: "Upload-Offset"),
           let offset = Int64(offsetStr) {
            return offset
        }
        return 0
    }
    
    /// Resume an interrupted Mux upload using tus protocol.
    /// Returns true if upload completed, false if the file is no longer available.
    func resumeMuxUpload(pending: PendingUpload) async throws -> Bool {
        guard let uploadUrlString = pending.uploadUrl,
              let uploadUrl = URL(string: uploadUrlString),
              let fileURL = URL(string: pending.fileURL),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            print("📤 [Tus] Cannot resume — file or upload URL missing")
            return false
        }
        
        let totalSize = pending.totalFileSize ?? {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 { return size }
            return Int64(0)
        }()
        
        guard totalSize > 0 else {
            print("📤 [Tus] Cannot resume — file size unknown")
            return false
        }
        
        isUploading = true
        uploadProgress = 0
        error = nil
        defer { isUploading = false }
        
        // HEAD to check how much Mux already received
        let offset = try await checkTusOffset(uploadUrl: uploadUrl)
        print("📤 [Tus] Resume check — offset: \(offset) / \(totalSize)")
        
        if offset >= totalSize {
            // Upload was already completed
            print("📤 [Tus] Upload already complete on Mux side")
            PendingUpload.clear()
            uploadProgress = 1.0
            return true
        }
        
        uploadProgress = Double(offset) / Double(totalSize)
        
        // Create temp file with remaining bytes (from offset to end)
        let remainingURL = try createOffsetFile(from: fileURL, offset: offset)
        defer { try? FileManager.default.removeItem(at: remainingURL) }
        
        // PATCH remaining bytes with tus headers
        var patchRequest = URLRequest(url: uploadUrl)
        patchRequest.httpMethod = "PATCH"
        patchRequest.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        patchRequest.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        patchRequest.setValue("\(offset)", forHTTPHeaderField: "Upload-Offset")
        let remaining = totalSize - offset
        patchRequest.setValue("\(remaining)", forHTTPHeaderField: "Content-Length")
        
        let (_, response) = try await uploadWithProgress(request: patchRequest, fileURL: remainingURL)
        
        guard let httpResp = response as? HTTPURLResponse,
              (200...204).contains(httpResp.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("📤 [Tus] ❌ Resume PATCH failed with status \(code)")
            throw UploadError.serverError(code, "Mux tus resume failed")
        }
        
        uploadProgress = 1.0
        PendingUpload.clear()
        print("📤 [Tus] ✅ Resumed upload complete!")
        return true
    }
    
    /// Create a temporary file containing bytes from `offset` to end of `originalURL`.
    private func createOffsetFile(from originalURL: URL, offset: Int64) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tus-resume-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        
        let readHandle = try FileHandle(forReadingFrom: originalURL)
        readHandle.seek(toFileOffset: UInt64(offset))
        let writeHandle = try FileHandle(forWritingTo: tempURL)
        
        let chunkSize = 1024 * 1024 // 1 MB
        while autoreleasepool(invoking: {
            let chunk = readHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return false }
            writeHandle.write(chunk)
            return true
        }) {}
        
        readHandle.closeFile()
        writeHandle.closeFile()
        return tempURL
    }
}

// MARK: - Upload Delegate (Progress Tracking)

private final class UploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    
    private var responseData = Data()
    
    init(onProgress: @escaping @Sendable (Double) -> Void, onComplete: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(responseData, task.response, nil)
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
