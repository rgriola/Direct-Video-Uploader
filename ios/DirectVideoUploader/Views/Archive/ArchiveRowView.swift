import AVFoundation
import Photos
import PhotosUI
// May 10, 2026 - 1:55pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

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
    @State private var showReuploadPicker = false
    @State private var reuploadNotice: String?

    /// Asset has no form response and user hasn't just submitted one
    private var needsDetails: Bool {
        asset.formResponse == nil && !formSubmitted
    }

    /// Upload is stuck — status is PROCESSING and created > 5 minutes ago
    var isStuckProcessing: Bool {
        guard asset.status == .processing, !reuploadComplete else { return false }
        guard let dateStr = asset.createdAt else { return true }
        guard let created = DVUDateFormatting.parseISO(dateStr) else { return true }
        return Date().timeIntervalSince(created) > 300  // 5 minutes
    }

    /// Consolidated display state — single source of truth for both the badge and
    /// the action buttons section. Priority order matters: check in this sequence.
    private enum RowStatus {
        case needsDetails  // yellow — form not yet filled
        case failed  // red — error or stuck processing
        case reuploading  // blue — active re-upload in progress
        case processing  // blue — waiting for Mux
        case ready  // green — fully processed
    }

    private var rowStatus: RowStatus {
        if needsDetails { return .needsDetails }
        if isReuploadingVideo { return .reuploading }
        if asset.status == .error || isStuckProcessing { return .failed }
        if asset.status == .processing { return .processing }
        return .ready
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
                        let url = URL(string: thumbnailUrl)
                    {
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
                        Text(
                            asset.formResponse?.slug ?? asset.originalFileName ?? asset
                                .mediasourceId ?? asset.id
                        )
                        .font(Theme.font16Medium)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(asset.mediasourceId ?? asset.id)
                                .font(Theme.mono13Medium)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)

                            switch rowStatus {
                            case .needsDetails:
                                Circle()
                                    .fill(Theme.yellow)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Needs Details")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.yellow)
                            case .failed:
                                Circle()
                                    .fill(Theme.red)
                                    .frame(width: Theme.statusDotSize, height: Theme.statusDotSize)
                                Text("Upload Failed")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.red)
                            case .reuploading:
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Uploading \(Int(reuploadProgress * 100))%")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            case .processing:
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Processing")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.blue)
                            case .ready:
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
                        if let slug = asset.formResponse?.slug ?? submittedFormData?["slug"],
                            !slug.isEmpty
                        {
                            metadataRow(label: "Slug", value: slug)
                        }
                        if let desc = asset.formResponse?.description
                            ?? submittedFormData?["description"], !desc.isEmpty
                        {
                            metadataRow(label: "Description", value: desc)
                        }
                        if let type = asset.formResponse?.type ?? submittedFormData?["type"],
                            !type.isEmpty
                        {
                            metadataRow(label: "Type", value: type)
                        }
                        if let priority = asset.formResponse?.priority
                            ?? submittedFormData?["priority"], !priority.isEmpty
                        {
                            metadataRow(label: "Priority", value: priority)
                        }

                        // Clip metadata (first clip)
                        if let clip = asset.clips?.first {
                            if let captured = clip.capturedAt {
                                metadataRow(label: "Recorded", value: formatShortDate(captured))
                            }

                            let techSpec = [clip.resolution, clip.codec].compactMap { $0 }.joined(
                                separator: " • ")
                            if !techSpec.isEmpty {
                                metadataRow(label: "Format", value: techSpec)
                            }

                            if let dur = clip.duration {
                                metadataRow(
                                    label: "Duration", value: DVUDateFormatting.duration(dur))
                            }

                            if let size = clip.fileSize {
                                metadataRow(
                                    label: "File Size", value: DVUDateFormatting.fileSize(size))
                            }

                            if let device = clip.deviceModel {
                                metadataRow(label: "Device", value: device)
                            }
                            if clip.gpsLat != nil, clip.gpsLon != nil {
                                metadataRow(
                                    label: "GPS",
                                    value: String(format: "%.4f, %.4f", clip.gpsLat!, clip.gpsLon!))
                            }

                        }
                    }

                    // Transcript panel (only if transcript exists)
                    if let clip = asset.clips?.first,
                        let transcript = clip.transcript, !transcript.isEmpty
                    {
                        Divider()
                            .background(Theme.separator)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "text.quote")
                                    .font(Theme.icon13)
                                    .foregroundStyle(Theme.blue)
                                Text("Transcript")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.primaryText)

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
                            .background(Theme.glassOverlay)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                    }
                    // Action buttons — equal width
                    switch rowStatus {
                    case .failed:
                        // Only show Re-upload when stuck
                        if hasSavedPHAsset || canAutoDiscover {
                            archiveButton(
                                icon: "arrow.clockwise.circle.fill", label: "Re-upload",
                                color: Theme.red
                            ) {
                                Task { await handleAutoReupload() }
                            }
                        } else {
                            archiveButton(
                                icon: "arrow.clockwise.circle.fill",
                                label: "Re-upload (pick video)",
                                color: Theme.red
                            ) {
                                reuploadNotice = nil
                                showReuploadPicker = true
                            }
                        }
                    case .reuploading:
                        // Show progress with thumbnail during re-upload
                        HStack(spacing: 12) {
                            // Small thumbnail
                            if let thumbnailUrl = asset.clips?.first?.thumbnailUrl,
                                let url = URL(string: thumbnailUrl)
                            {
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
                                    .overlay(
                                        Image(systemName: "film").foregroundStyle(
                                            Theme.tertiaryText
                                        ).font(Theme.icon13))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Uploading \(Int(reuploadProgress * 100))%")
                                    .font(Theme.font13Semibold)
                                    .foregroundStyle(Theme.blue)
                                ProgressView(value: reuploadProgress)
                                    .tint(Theme.blue)
                            }
                        }
                    case .processing:
                        // Waiting for Mux to process
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Processing on server\u{2026}")
                                .font(Theme.font13Semibold)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.buttonPaddingV)
                    case .needsDetails, .ready:
                        // Normal buttons: View, Slack, Details
                        HStack(spacing: 8) {
                            if let msId = asset.mediasourceId,
                                let url = ServerConfig.clipURL(msId)
                            {
                                archiveButton(
                                    icon: "play.circle.fill", label: "View", color: Theme.green
                                ) {
                                    UIApplication.shared.open(url)
                                }
                            }

                            archiveButton(
                                icon: "paperplane.fill", label: "Slack", color: Theme.purple
                            ) {
                                showSlackShare = true
                            }

                            if rowStatus == .needsDetails {
                                archiveButton(
                                    icon: "square.and.pencil", label: "Add Details",
                                    color: Theme.yellow
                                ) {
                                    showFormSheet = true
                                }
                            } else {
                                archiveButton(
                                    icon: "checkmark.circle.fill", label: "Details",
                                    color: Theme.green.opacity(0.5)
                                ) {}
                                .allowsHitTesting(false)
                            }
                        }
                    }

                    if let reuploadNotice, reuploadError == nil {
                        Label(reuploadNotice, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.warningText)
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
        .background(Theme.cardBg)
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
        .photosPicker(
            isPresented: $showReuploadPicker,
            selection: $selectedVideoItem,
            matching: .videos,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
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
    private func archiveButton(
        icon: String, label: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
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
        FormField.defaultVideoFields()
    }

    private func submitFormFromArchive(formData: [String: String]) async {
        var request = auth.authenticatedRequest(for: ServerConfig.formURL(asset.id), method: "POST")
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

    /// Auto re-upload of the camera original, found by stored Photos identifier or by capture date.
    /// A Photos video only counts as a match when its length equals the uploaded clip's, so the
    /// untrimmed source of a trimmed upload is never sent. Otherwise the person picks the video.
    private func handleAutoReupload() async {
        guard !isReuploadingVideo else { return }
        isReuploadingVideo = true
        reuploadProgress = 0
        reuploadError = nil
        reuploadNotice = nil

        let status = await OriginalVideoLoader.requestReadWriteAccessIfNeeded()
        guard OriginalVideoLoader.canRead(status) else {
            askToPickVideo("Photo Library access is off, so pick the video to re-upload.")
            return
        }

        guard let identifier = findMatchingOriginal() else {
            askToPickVideo("Couldn't find a matching video in Photos. Pick the video to re-upload.")
            return
        }

        defer { if reuploadError != nil { isReuploadingVideo = false } }

        do {
            try await uploadOriginal(localIdentifier: identifier)
        } catch {
            reuploadError = "Re-upload failed: \(error.localizedDescription)"
            print("❌ [Archive] Auto re-upload failed: \(error)")
        }
    }

    /// Photos identifier of a video with the same length as the uploaded clip, if one exists.
    private func findMatchingOriginal() -> String? {
        let clipDuration = asset.clips?.first?.duration

        // Strategy 1: stored identifier (saved at upload, or the saved trimmed copy)
        if let storedId = PHAssetIdentifierStore.identifier(for: asset.id),
            let photosDuration = OriginalVideoLoader.duration(ofAssetWithIdentifier: storedId)
        {
            if OriginalVideoLoader.isSameLength(
                photosDuration: photosDuration, clipDuration: clipDuration)
            {
                print("📷 [Archive] Found video by stored PHAsset ID")
                return storedId
            }
            print("⚠️ [Archive] Stored PHAsset length differs from the uploaded clip; skipping")
        }

        // Strategy 2: auto-discover by capturedAt date from clip metadata
        if let capturedAtStr = asset.clips?.first?.capturedAt,
            let capturedDate = DVUDateFormatting.parseISO(capturedAtStr),
            let phAsset = discoverPHAsset(capturedAt: capturedDate, duration: clipDuration),
            OriginalVideoLoader.isSameLength(
                photosDuration: phAsset.duration, clipDuration: clipDuration)
        {
            print("📷 [Archive] Auto-discovered video by capturedAt: \(capturedAtStr)")
            PHAssetIdentifierStore.save(
                assetId: asset.id, phAssetIdentifier: phAsset.localIdentifier)
            return phAsset.localIdentifier
        }

        return nil
    }

    private func askToPickVideo(_ message: String) {
        isReuploadingVideo = false
        reuploadNotice = message
        // The picker takes VoiceOver focus, so speak the reason before it opens.
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        showReuploadPicker = true
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

    /// Re-upload of a video the person picked: the camera original when Photos access allows it,
    /// otherwise the picker's copy of the current version (no transcoding).
    private func handleReupload(item: PhotosPickerItem) async {
        guard !isReuploadingVideo else { return }
        isReuploadingVideo = true
        reuploadProgress = 0
        reuploadError = nil
        reuploadNotice = nil
        defer { if reuploadError != nil { isReuploadingVideo = false } }

        do {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if OriginalVideoLoader.canRead(status),
                let identifier = item.itemIdentifier,
                OriginalVideoLoader.duration(ofAssetWithIdentifier: identifier) != nil
            {
                PHAssetIdentifierStore.save(assetId: asset.id, phAssetIdentifier: identifier)
                try await uploadOriginal(localIdentifier: identifier)
                return
            }

            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                reuploadError = "Could not load video from Photos library"
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url.deletingLastPathComponent()) }
            try await performUpload(fileURL: movie.url, metadata: nil)
        } catch {
            reuploadError = "Re-upload failed: \(error.localizedDescription)"
            print("❌ [Archive] Re-upload failed: \(error)")
        }
    }

    /// Copies the camera original out of Photos (downloading from iCloud if needed) and uploads it.
    private func uploadOriginal(localIdentifier: String) async throws {
        let original = try await OriginalVideoLoader.loadOriginal(localIdentifier: localIdentifier)
        defer { try? FileManager.default.removeItem(at: original.fileURL.deletingLastPathComponent()) }
        try await performUpload(fileURL: original.fileURL, metadata: original.metadata)
    }

    /// Shared upload logic for both auto and manual re-upload
    private func performUpload(fileURL: URL, metadata: VideoMetadata?) async throws {
        let resolvedMetadata: VideoMetadata
        if let metadata {
            resolvedMetadata = metadata
        } else {
            resolvedMetadata = await VideoMetadataExtractor.extract(from: fileURL)
        }

        guard let token = auth.token else {
            reuploadError = "Not authenticated"
            return
        }

        let uploader = VideoUploadService()

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                reuploadProgress = uploader.uploadProgress
            }
        }
        defer { progressTask.cancel() }

        let _ = try await uploader.uploadViaMux(
            assetId: asset.id,
            fileURL: fileURL,
            token: token,
            metadata: resolvedMetadata
        )

        reuploadProgress = 1.0
        reuploadComplete = true
        isReuploadingVideo = false
        print("✅ [Archive] Re-upload complete for asset: \(asset.id)")

        try? await Task.sleep(for: .seconds(2))
        onFormSubmitted?()
    }
}
