import Foundation
import Observation

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
        
        // Step 2: PUT the raw video file directly to Mux's upload URL
        var putRequest = URLRequest(url: uploadUrl)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64 {
            putRequest.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        }
        
        let (_, putResponse) = try await uploadWithProgress(request: putRequest, fileURL: fileURL)
        
        guard let putHttp = putResponse as? HTTPURLResponse, putHttp.statusCode == 200 else {
            let code = (putResponse as? HTTPURLResponse)?.statusCode ?? 0
            print("📤 [Mux] ❌ PUT to Mux failed with status \(code)")
            throw UploadError.serverError(code, "Mux upload failed")
        }
        
        uploadProgress = 1.0
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
    
    // MARK: - Upload with Progress
    
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
            
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.resume()
        }
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
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(responseData, task.response, nil)
        }
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
