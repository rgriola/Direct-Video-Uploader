import Foundation
import UIKit
import Observation

/// Response from POST /api/assets/:id/photo-upload — ImageKit auth + clip mapping.
struct PhotoUploadAuthResponse: Codable {
    let token: String
    let expire: Int
    let signature: String
    let uploadUrl: String       // "https://upload.imagekit.io/api/v2/files/upload"
    let clipId: String
    let urlEndpoint: String     // "https://ik.imagekit.io/rgriola"
}

/// Response from POST /api/assets/:id/photo-uploaded — confirmation.
struct PhotoUploadedResponse: Codable {
    let ok: Bool
    let clipId: String
    let allDone: Bool
    let readyClips: Int
    let totalClips: Int
}

// MARK: - Photo Upload Service

/// Handles the photo upload pipeline: server auth → ImageKit PUT → server confirm.
/// Mirrors VideoUploadService but uses ImageKit instead of Mux.
@MainActor
@Observable
final class PhotoUploadService {
    
    // MARK: - Batch State
    
    var batchProgress: Double = 0       // 0→1 across all photos in batch
    var currentPhotoIndex: Int = 0
    var totalPhotos: Int = 0
    var isUploading = false
    var isCancelled = false
    var error: String?
    
    /// Clip IDs returned by server auth — used for form recovery
    private(set) var clipIds: [String] = []
    
    /// Active upload task — can be cancelled
    private var activeTask: URLSessionUploadTask?
    
    // MARK: - Retry Configuration
    
    private let maxRetries = 3
    private let baseRetryDelay: TimeInterval = 2.0  // 2s, 4s, 8s exponential backoff
    
    // MARK: - Upload Batch
    
    /// Upload a batch of photos to ImageKit via the server's auth flow.
    /// Returns the updated items with their upload states.
    ///
    /// Flow per photo:
    /// 1. POST /api/assets/:id/photo-upload → get ImageKit auth params + clipId
    /// 2. Multipart POST to ImageKit upload API with auth params
    /// 3. POST /api/assets/:id/photo-uploaded → confirm with imageKitUrl
    func uploadBatch(
        assetId: String,
        items: [PhotoItem],
        token: String
    ) async -> [PhotoItem] {
        isUploading = true
        isCancelled = false
        batchProgress = 0
        currentPhotoIndex = 0
        totalPhotos = items.count
        error = nil
        clipIds = []
        defer { isUploading = false }
        
        var updatedItems = items
        
        for (index, item) in items.enumerated() {
            // Check for cancellation before each photo
            if isCancelled {
                for remaining in index..<items.count {
                    updatedItems[remaining].uploadState = .failed(reason: "Cancelled")
                }
                print("📸 ❌ Upload cancelled at photo \(index + 1)/\(items.count)")
                break
            }
            
            currentPhotoIndex = index
            
            // Retry loop per photo
            var lastError: Error?
            var succeeded = false
            
            for attempt in 1...maxRetries {
                if isCancelled { break }
                
                do {
                    // Step 1: Get ImageKit auth params from server
                    let auth = try await requestPhotoUploadAuth(
                        assetId: assetId,
                        index: index,
                        item: item,
                        token: token
                    )
                    
                    clipIds.append(auth.clipId)
                    updatedItems[index].uploadState = .uploading(progress: 0)
                    
                    // Step 2: Upload to ImageKit
                    let imageKitUrl = try await uploadToImageKit(
                        item: item,
                        auth: auth,
                        batchIndex: index,
                        batchTotal: items.count
                    )
                    
                    // Step 3: Confirm with server
                    try await confirmPhotoUploaded(
                        assetId: assetId,
                        clipId: auth.clipId,
                        imageKitUrl: imageKitUrl,
                        token: token
                    )
                    
                    updatedItems[index].uploadState = .uploaded(imageKitUrl: imageKitUrl)
                    let retryNote = attempt > 1 ? " (attempt \(attempt))" : ""
                    print("📸 [\(index + 1)/\(items.count)] Photo uploaded: \(item.fileName)\(retryNote)")
                    succeeded = true
                    break
                    
                } catch {
                    lastError = error
                    if attempt < maxRetries && !isCancelled {
                        let delay = baseRetryDelay * pow(2.0, Double(attempt - 1))
                        print("📸 ⏳ [\(index + 1)/\(items.count)] Retry \(attempt)/\(maxRetries) in \(Int(delay))s: \(error.localizedDescription)")
                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
            }
            
            if !succeeded && !isCancelled {
                let reason = lastError?.localizedDescription ?? "Unknown error"
                updatedItems[index].uploadState = .failed(reason: reason)
                print("📸 ❌ [\(index + 1)/\(items.count)] Photo failed after \(maxRetries) attempts: \(reason)")
                // Continue with remaining photos (don't abort batch)
            }
            
            // Update batch progress
            batchProgress = Double(index + 1) / Double(items.count)
        }
        
        let failed = updatedItems.filter {
            if case .failed = $0.uploadState { return true }
            return false
        }.count
        
        if isCancelled {
            self.error = "Upload cancelled"
        } else if failed > 0 {
            self.error = "\(failed) of \(items.count) photos failed to upload"
        }
        
        return updatedItems
    }
    
    // MARK: - Cancellation
    
    /// Cancel the current batch upload. The active photo finishes its current network
    /// request, then remaining photos are skipped.
    func cancelUpload() {
        isCancelled = true
        activeTask?.cancel()
        activeTask = nil
        print("📸 ❌ Cancel requested")
    }
    
    // MARK: - Step 1: Request Auth
    
    private func requestPhotoUploadAuth(
        assetId: String,
        index: Int,
        item: PhotoItem,
        token: String
    ) async throws -> PhotoUploadAuthResponse {
        let url = ServerConfig.photoUploadURL(assetId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let metadata: [String: Any] = [
            "fileName": item.fileName,
            "fileSize": item.fileSize,
            "format": item.format,
            "width": item.width,
            "height": item.height,
            "capturedAt": item.capturedAt ?? "",
            "gpsLat": item.gpsLat ?? NSNull(),
            "gpsLon": item.gpsLon ?? NSNull(),
            "gpsAltitude": item.gpsAltitude ?? NSNull(),
            "deviceModel": item.deviceModel,
            "osVersion": item.osVersion,
            "resolution": "\(item.width)×\(item.height)",
            "orientation": item.width >= item.height ? "landscape" : "portrait",
        ]
        
        let body: [String: Any] = ["index": index, "metadata": metadata]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw UploadError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }
        
        return try JSONDecoder().decode(PhotoUploadAuthResponse.self, from: data)
    }
    
    // MARK: - Step 2: Upload to ImageKit
    
    private func uploadToImageKit(
        item: PhotoItem,
        auth: PhotoUploadAuthResponse,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> String {
        guard let url = URL(string: auth.uploadUrl) else {
            throw UploadError.invalidResponse
        }
        
        // Get image data in original format (JPEG or HEIC)
        let imageData: Data
        if item.format == "HEIC" {
            // Export as HEIC to preserve original quality
            if let heicData = item.image.heicData() {
                imageData = heicData
            } else {
                // Fallback to max-quality JPEG
                imageData = item.image.jpegData(compressionQuality: 1.0) ?? Data()
            }
        } else {
            // JPEG — max quality, no compression
            imageData = item.image.jpegData(compressionQuality: 1.0) ?? Data()
        }
        
        guard !imageData.isEmpty else {
            throw UploadError.fileNotFound
        }
        
        // Build multipart form data (ImageKit upload API requires multipart)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        
        // File field
        body.appendMultipart(boundary: boundary, name: "file", fileName: item.fileName,
                            mimeType: item.format == "HEIC" ? "image/heic" : "image/jpeg",
                            data: imageData)
        
        // Required fields
        body.appendMultipartField(boundary: boundary, name: "fileName", value: item.fileName)
        body.appendMultipartField(boundary: boundary, name: "token", value: auth.token)
        body.appendMultipartField(boundary: boundary, name: "expire", value: "\(auth.expire)")
        body.appendMultipartField(boundary: boundary, name: "signature", value: auth.signature)
        body.appendMultipartField(boundary: boundary, name: "useUniqueFileName", value: "true")
        body.appendMultipartField(boundary: boundary, name: "folder", value: "/fixer-photos")
        
        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        // Upload with progress tracking
        let (data, response) = try await uploadWithProgress(
            request: request,
            bodyData: body,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        )
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let respBody = String(data: data, encoding: .utf8) ?? "Unknown"
            throw UploadError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0, respBody)
        }
        
        // Parse ImageKit response for the URL
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageKitUrl = json["url"] as? String else {
            throw UploadError.invalidResponse
        }
        
        return imageKitUrl
    }
    
    // MARK: - Step 3: Confirm Upload
    
    private func confirmPhotoUploaded(
        assetId: String,
        clipId: String,
        imageKitUrl: String,
        token: String
    ) async throws {
        let url = ServerConfig.photoUploadedURL(assetId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "clipId": clipId,
            "imageKitUrl": imageKitUrl,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw UploadError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }
    }
    
    // MARK: - Upload with Progress
    
    private func uploadWithProgress(
        request: URLRequest,
        bodyData: Data,
        batchIndex: Int,
        batchTotal: Int
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoUploadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Blend per-photo progress into batch progress
                        let perPhotoWeight = 1.0 / Double(batchTotal)
                        let base = Double(batchIndex) * perPhotoWeight
                        self.batchProgress = base + progress * perPhotoWeight
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
            
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForResource = 600  // 10 min for large/slow uploads
            config.timeoutIntervalForRequest = 120   // 2 min per request
            
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.uploadTask(with: request, from: bodyData)
            
            // Store reference for cancellation
            Task { @MainActor [weak self] in
                self?.activeTask = task
            }
            
            task.resume()
        }
    }
}

// MARK: - Upload Delegate (Progress)

private final class PhotoUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    
    private var responseData = Data()
    
    init(onProgress: @escaping @Sendable (Double) -> Void,
         onComplete: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
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
}

// MARK: - UIImage HEIC Export

extension UIImage {
    /// Export image as HEIC data (preserves quality, smaller than JPEG).
    func heicData(compressionQuality: CGFloat = 1.0) -> Data? {
        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Data Multipart Helpers

extension Data {
    mutating func appendMultipart(boundary: String, name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
    
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
