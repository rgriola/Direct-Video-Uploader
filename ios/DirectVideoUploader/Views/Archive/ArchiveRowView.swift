import SwiftUI
import PhotosUI
import Photos
import AVFoundation

/// A single expandable row in the archive list showing upload metadata and actions.
struct ArchiveRowView: View {
    let asset: Asset
    var onFormSubmitted: (() -> Void)?
    @Environment(WebSocketService.self) private var ws
    @Environment(AuthService.self) private var auth
    @State private var isExpanded = false
    @State private var showSlackShare = false
    @State private var showFormSheet = false
    @State private var formSubmitted = false
    @State private var submittedFormData: [String: String]?
    
    // Re-upload state
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isReuploadingVideo = false
    @State private var reuploadProgress: Double = 0
    @State private var reuploadError: String?
    @State private var reuploadComplete = false
    
    /// Asset has no form response and user hasn't just submitted one
    private var needsDetails: Bool {
        asset.formResponse == nil && !formSubmitted
    }
    
    /// Upload is stuck — status is PROCESSING and created > 5 minutes ago
    var isStuckProcessing: Bool {
        guard asset.status == .processing, !reuploadComplete else { return false }
        guard let dateStr = asset.createdAt else { return true }
        guard let created = DVUDateFormatting.parseISO(dateStr) else { return true }
        return Date().timeIntervalSince(created) > 300 // 5 minutes
    }
    
    /// Whether we have a stored PHAsset identifier for auto-re-upload
    private var hasSavedPHAsset: Bool {
        PHAssetIdentifierStore.identifier(for: asset.id) != nil
    }
    
    /// Whether we can auto-discover the video by capturedAt date
    private var canAutoDiscover: Bool {
        asset.clips?.first?.capturedAt != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Collapsed Row (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail
                    if let thumbnailUrl = asset.clips?.first?.thumbnailUrl,
                       let url = URL(string: thumbnailUrl) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.radiusSm)
                                    .fill(Theme.cardBg)
                                Image(systemName: "film")
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.radiusSm)
                                .fill(Theme.cardBg)
                                .frame(width: 50, height: 50)
                            Text("🎬")
                                .font(Theme.display32)
                        }
                    }
                    
                    // File info
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.originalFileName ?? asset.mediasourceId ?? asset.id)
                            .font(Theme.font16Medium)
                            .foregroundStyle(Theme.white)
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            Text(asset.mediasourceId ?? asset.id)
                                .font(Theme.mono13Medium)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                            
                            if needsDetails {
                                Circle()
                                    .fill(Theme.yellow)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Needs Details")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.yellow)
                            } else if asset.status == .error || isStuckProcessing {
                                Circle()
                                    .fill(Theme.red)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Upload Failed")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.red)
                            } else if isReuploadingVideo {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Uploading \(Int(reuploadProgress * 100))%")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            } else if asset.status == .processing {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Processing")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            } else {
                                Circle()
                                    .fill(Theme.green)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Ready")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.green)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Date + chevron
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(formatShortDate(asset.createdAt))
                            .font(Theme.font11Regular)
                            .foregroundStyle(Theme.secondaryText)
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Theme.icon11)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            
            // MARK: - Expanded Detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .background(Theme.separator)
                    
                    // Metadata grid
                    VStack(alignment: .leading, spacing: 6) {
                        if let mid = asset.mediasourceId {
                            metadataRow(label: "Mediasource", value: mid)
                        }
                        if let slug = asset.formResponse?.slug ?? submittedFormData?["slug"], !slug.isEmpty {
                            metadataRow(label: "Slug", value: slug)
                        }
                        if let type = asset.formResponse?.type ?? submittedFormData?["type"], !type.isEmpty {
                            metadataRow(label: "Type", value: type)
                        }
                        if let desc = asset.formResponse?.description ?? submittedFormData?["description"], !desc.isEmpty {
                            metadataRow(label: "Description", value: desc)
                        }
                        if let priority = asset.formResponse?.priority ?? submittedFormData?["priority"], !priority.isEmpty {
                            metadataRow(label: "Priority", value: priority)
                        }
                        
                        // Clip metadata (first clip)
                        if let clip = asset.clips?.first {
                            if let res = clip.resolution {
                                metadataRow(label: "Resolution", value: res)
                            }
                            if let codec = clip.codec {
                                metadataRow(label: "Codec", value: codec)
                            }
                            if let dur = clip.duration {
                                metadataRow(label: "Duration", value: DVUDateFormatting.duration(dur))
                            }
                            if let size = clip.fileSize {
                                metadataRow(label: "File Size", value: DVUDateFormatting.fileSize(size))
                            }
                            if let device = clip.deviceModel {
                                metadataRow(label: "Device", value: device)
                            }
                            if clip.gpsLat != nil, clip.gpsLon != nil {
                                metadataRow(label: "GPS", value: String(format: "%.4f, %.4f", clip.gpsLat!, clip.gpsLon!))
                            }
                            if let captured = clip.capturedAt {
                                metadataRow(label: "Captured", value: formatShortDate(captured))
                            }
                        }
                    }
                    
                    // Transcript panel (only if transcript exists)
                    if let clip = asset.clips?.first,
                       let transcript = clip.transcript, !transcript.isEmpty {
                        Divider()
                            .background(Theme.separator)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.quote")
                                    .font(Theme.icon13)
                                    .foregroundStyle(Theme.blue)
                                Text("Transcript")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.white)
                                
                                Spacer()
                                
                                // Copy button
                                Button {
                                    UIPasteboard.general.string = transcript
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(Theme.icon13)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                            
                            // Scrollable transcript text
                            ScrollView {
                                Text(transcript)
                                    .font(Theme.font13Regular)
                                    .foregroundStyle(Theme.metaText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .padding(10)
                            .background(Theme.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                    }
                    
                    // Action buttons — equal width
                    if asset.status == .error || isStuckProcessing {
                        // Only show Re-upload when stuck
                        if hasSavedPHAsset || canAutoDiscover {
                            archiveButton(icon: "arrow.clockwise.circle.fill", label: "Re-upload", color: Theme.red) {
                                Task { await handleAutoReupload() }
                            }
                        } else {
                            PhotosPicker(
                                selection: $selectedVideoItem,
                                matching: .videos
                            ) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                    Text("Re-upload (pick video)")
                                }
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.buttonPaddingV)
                                .background(Theme.red.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
                            }
                            .buttonStyle(.plain)
                        }
                    } else if isReuploadingVideo {
                        // Show progress with thumbnail during re-upload
                        HStack(spacing: 12) {
                            // Small thumbnail
                            if let thumbnailUrl = asset.clips?.first?.thumbnailUrl,
                               let url = URL(string: thumbnailUrl) {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 6).fill(Theme.cardBg)
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.cardBg)
                                    .frame(width: 36, height: 36)
                                    .overlay(Image(systemName: "film").foregroundStyle(Theme.tertiaryText).font(Theme.icon13))
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Uploading \\(Int(reuploadProgress * 100))%")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.blue)
                                ProgressView(value: reuploadProgress)
                                    .tint(Theme.blue)
                            }
                        }
                    } else if asset.status == .processing {
                        // Re-upload sent, waiting for Mux to process
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Processing on server\u{2026}")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.buttonPaddingV)
                    } else {
                        // Normal buttons: View, Slack, Details
                        HStack(spacing: 8) {
                            if let msId = asset.mediasourceId,
                               let url = ServerConfig.clipURL(msId) {
                                archiveButton(icon: "play.circle.fill", label: "View", color: Theme.green) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            
                            archiveButton(icon: "paperplane.fill", label: "Slack", color: Theme.purple) {
                                showSlackShare = true
                            }
                            
                            if needsDetails {
                                archiveButton(icon: "square.and.pencil", label: "Add Details", color: Theme.yellow) {
                                    showFormSheet = true
                                }
                            } else {
                                archiveButton(icon: "checkmark.circle.fill", label: "Details", color: Theme.green.opacity(0.5)) { }
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    
                    // Re-upload error
                    if let reuploadError {
                        Text(reuploadError)
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        .sheet(isPresented: $showSlackShare) {
            SlackShareSheet(
                mediasourceId: asset.mediasourceId,
                originalFileName: asset.originalFileName,
                onSend: { text in
                    showSlackShare = false
                    ws.sendMessage(text: text, assetId: asset.id)
                },
                onDismiss: { showSlackShare = false }
            )
        }
        .sheet(isPresented: $showFormSheet) {
            ContextFormView(
                fields: buildFormFields(),
                originalFileName: asset.originalFileName,
                capturedAt: asset.clips?.first?.capturedAt,
                clipCount: asset.clipCount,
                duration: asset.clips?.first?.duration,
                thumbnail: nil,
                onSubmit: { formData in
                    showFormSheet = false
                    Task { await submitFormFromArchive(formData: formData) }
                },
                onCancel: {
                    showFormSheet = false
                }
            )
        }
        .onChange(of: selectedVideoItem) { _, newItem in
            guard let newItem else { return }
            selectedVideoItem = nil
            Task { await handleReupload(item: newItem) }
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(Theme.font11Regular)
                .foregroundStyle(Theme.metaText)
                .lineLimit(3)
        }
    }
    
    @ViewBuilder
    private func archiveButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(Theme.font13Semibold)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.buttonPaddingV)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Theme.buttonCornerRadius))
        }
        .buttonStyle(.plain)
    }
    
    private func formatShortDate(_ dateStr: String?) -> String {
        guard let dateStr else { return "" }
        return DVUDateFormatting.shortDate(dateStr)
    }
    
    private func buildFormFields() -> [FormField] {
        var fields: [FormField] = []
        fields.append(FormField(id: "slug", label: "Slug / Title", type: "text", value: nil))
        fields.append(FormField(id: "type", label: "Content Type", type: "select", options: ["Raw", "Cut"]))
        fields.append(FormField(id: "description", label: "Description / Notes", type: "textarea"))
        fields.append(FormField(id: "priority", label: "Priority", type: "select", value: "Low", options: ["Low", "Medium", "High", "Critical"]))
        return fields
    }
    
    private func submitFormFromArchive(formData: [String: String]) async {
        guard let token = auth.token else { return }
        let url = ServerConfig.formURL(asset.id)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: formData)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                PendingForm.clear()
                // Update local state immediately — switches to Ready + Details button
                formSubmitted = true
                submittedFormData = formData
                print("✅ [Archive] Form submitted for asset: \(asset.id)")
                // Refresh parent list so server data is in sync
                onFormSubmitted?()
            }
        } catch {
            print("❌ [Archive] Form submit failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Re-upload
    
    /// Auto re-upload using stored PHAsset identifier or auto-discovery by capturedAt
    private func handleAutoReupload() async {
        isReuploadingVideo = true
        reuploadProgress = 0
        reuploadError = nil
        
        do {
            // Strategy 1: Use stored PHAsset identifier
            if let phId = PHAssetIdentifierStore.identifier(for: asset.id) {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [phId], options: nil)
                if let phAsset = fetchResult.firstObject {
                    print("📷 [Archive] Found video by stored PHAsset ID")
                    let tempURL = try await exportVideoToTemp(phAsset: phAsset)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    try await performUpload(fileURL: tempURL)
                    return
                }
            }
            
            // Strategy 2: Auto-discover by capturedAt date from clip metadata
            if let capturedAtStr = asset.clips?.first?.capturedAt,
               let capturedDate = parseISO8601(capturedAtStr) {
                let phAsset = discoverPHAsset(capturedAt: capturedDate, duration: asset.clips?.first?.duration)
                if let phAsset {
                    print("📷 [Archive] Auto-discovered video by capturedAt: \(capturedAtStr)")
                    // Save for future re-uploads
                    PHAssetIdentifierStore.save(assetId: asset.id, phAssetIdentifier: phAsset.localIdentifier)
                    let tempURL = try await exportVideoToTemp(phAsset: phAsset)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    try await performUpload(fileURL: tempURL)
                    return
                }
            }
            
            // Both strategies failed
            reuploadError = "Could not find original video in Photos library"
            isReuploadingVideo = false
            
        } catch {
            reuploadError = "Re-upload failed: \(error.localizedDescription)"
            isReuploadingVideo = false
            print("❌ [Archive] Auto re-upload failed: \(error)")
        }
    }
    
    /// Search Photos library for a video matching the capturedAt date and optional duration
    private func discoverPHAsset(capturedAt: Date, duration: Int?) -> PHAsset? {
        let options = PHFetchOptions()
        // Search within a 2-second window around the capture date
        let startDate = capturedAt.addingTimeInterval(-1)
        let endDate = capturedAt.addingTimeInterval(1)
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.video.rawValue, startDate as NSDate, endDate as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 5
        
        let results = PHAsset.fetchAssets(with: options)
        
        // If only one match, use it
        if results.count == 1 {
            return results.firstObject
        }
        
        // If multiple matches and we have duration, pick the closest match
        if let duration, results.count > 1 {
            var bestMatch: PHAsset?
            var bestDiff = Double.infinity
            results.enumerateObjects { phAsset, _, _ in
                let diff = abs(phAsset.duration - Double(duration))
                if diff < bestDiff {
                    bestDiff = diff
                    bestMatch = phAsset
                }
            }
            return bestMatch
        }
        
        return results.firstObject
    }
    
    private func parseISO8601(_ str: String) -> Date? {
        DVUDateFormatting.parseISO(str)
    }
    
    /// Fallback re-upload using PhotosPicker selection
    private func handleReupload(item: PhotosPickerItem) async {
        isReuploadingVideo = true
        reuploadProgress = 0
        reuploadError = nil
        
        do {
            guard let videoData = try await item.loadTransferable(type: Data.self) else {
                reuploadError = "Could not load video"
                isReuploadingVideo = false
                return
            }
            
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(asset.originalFileName ?? "reupload.mov")
            try videoData.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            // Save the new PHAsset identifier for future re-uploads
            if let newPhId = item.itemIdentifier {
                PHAssetIdentifierStore.save(assetId: asset.id, phAssetIdentifier: newPhId)
            }
            
            try await performUpload(fileURL: tempURL)
        } catch {
            reuploadError = "Re-upload failed: \(error.localizedDescription)"
            isReuploadingVideo = false
            print("❌ [Archive] Re-upload failed: \(error)")
        }
    }
    
    /// Shared upload logic for both auto and manual re-upload
    private func performUpload(fileURL: URL) async throws {
        let metadata = await VideoMetadataExtractor.extract(from: fileURL)
        
        guard let token = auth.token else {
            reuploadError = "Not authenticated"
            isReuploadingVideo = false
            return
        }
        
        let uploader = VideoUploadService()
        
        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                reuploadProgress = uploader.uploadProgress
            }
        }
        
        let _ = try await uploader.uploadViaMux(
            assetId: asset.id,
            fileURL: fileURL,
            token: token,
            metadata: metadata
        )
        
        progressTask.cancel()
        reuploadProgress = 1.0
        reuploadComplete = true
        isReuploadingVideo = false
        print("✅ [Archive] Re-upload complete for asset: \(asset.id)")
        
        try? await Task.sleep(for: .seconds(2))
        onFormSubmitted?()
    }
    
    /// Export a PHAsset video to a temporary file URL
    private func exportVideoToTemp(phAsset: PHAsset) async throws -> URL {
        let fileName = asset.originalFileName ?? "reupload.mov"
        return try await phAssetToTempFile(phAsset: phAsset, fileName: fileName)
    }
}

/// Standalone (non-actor-isolated) export so the PHImageManager callback
/// doesn't trigger a main-actor assertion in Swift 6.
private func phAssetToTempFile(phAsset: PHAsset, fileName: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
            guard let urlAsset = avAsset as? AVURLAsset else {
                continuation.resume(throwing: ReuploadError.videoExportFailed)
                return
            }
            
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: tempURL)
            
            do {
                try FileManager.default.copyItem(at: urlAsset.url, to: tempURL)
                continuation.resume(returning: tempURL)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum ReuploadError: LocalizedError {
    case videoExportFailed
    
    var errorDescription: String? {
        switch self {
        case .videoExportFailed: return "Could not export video from Photos library"
        }
    }
}
