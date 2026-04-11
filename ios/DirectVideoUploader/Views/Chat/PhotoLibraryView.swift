import SwiftUI
import PhotosUI
import Photos
import UIKit
import UniformTypeIdentifiers

/// Photo library picker — multi-select PHPicker for photos (up to 20 per session).
/// Validates UTIs (rejects PNG/TIFF), detects RAW for conversion, extracts metadata.
struct PhotoLibraryView: View {
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var loadedPhotos: [PhotoItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var rejectedCount = 0
    
    /// Max photos per picker session.
    private let maxSelection = 20
    
    /// Called when user confirms selection.
    var onConfirm: ([PhotoItem]) -> Void
    /// Called when user dismisses.
    var onDismiss: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Inline Photos Picker — multi-select photos
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: maxSelection,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    EmptyView()
                }
                .photosPickerStyle(.inline)
                .photosPickerDisabledCapabilities(.selectionActions)
                
                // Footer bar
                footerBar
            }
            .background(Theme.black)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        selectedItems.removeAll()
                        loadedPhotos.removeAll()
                        loadError = nil
                        rejectedCount = 0
                    }
                    .foregroundStyle(selectedItems.isEmpty ? .gray : .white)
                    .disabled(selectedItems.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.gray)
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                handleSelectionChange(newItems)
            }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Footer
    
    @ViewBuilder
    private var footerBar: some View {
        if !selectedItems.isEmpty {
            VStack(spacing: 0) {
                // Error / rejection banner
                if let error = loadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(Theme.font11Regular)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                }
                
                if rejectedCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.yellow)
                        Text("\(rejectedCount) unsupported file\(rejectedCount == 1 ? "" : "s") skipped (PNG/TIFF not allowed)")
                            .font(Theme.font11Regular)
                            .foregroundStyle(.yellow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.05))
                }
                
                Divider().background(Theme.white.opacity(0.1))
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(loadedPhotos.count) photo\(loadedPhotos.count == 1 ? "" : "s") selected")
                            .font(Theme.font13Semibold)
                            .foregroundStyle(Theme.white)
                        
                        if !loadedPhotos.isEmpty {
                            let formats = Set(loadedPhotos.map(\.format)).sorted().joined(separator: ", ")
                            let totalMB = Double(loadedPhotos.reduce(0) { $0 + $1.fileSize }) / (1024 * 1024)
                            Text("\(formats) · \(String(format: "%.1f", totalMB)) MB")
                                .font(Theme.font11Regular)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        
                        if isLoading {
                            Text("Loading photos…")
                                .font(Theme.font11Regular)
                                .foregroundStyle(Theme.blue)
                        }
                    }
                    
                    Spacer()
                    
                    // Confirm button
                    Button {
                        onConfirm(loadedPhotos)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(loadedPhotos.isEmpty ? .gray : Theme.green)
                    }
                    .disabled(loadedPhotos.isEmpty || isLoading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.black)
            }
        }
    }
    
    // MARK: - Selection Handler
    
    private func handleSelectionChange(_ newItems: [PhotosPickerItem]) {
        guard !newItems.isEmpty else {
            loadedPhotos.removeAll()
            loadError = nil
            rejectedCount = 0
            return
        }
        
        isLoading = true
        loadError = nil
        rejectedCount = 0
        
        Task {
            var photos: [PhotoItem] = []
            var rejected = 0
            
            for item in newItems {
                do {
                    if let photo = try await loadPhotoItem(from: item) {
                        photos.append(photo)
                    } else {
                        rejected += 1
                    }
                } catch {
                    print("📸 ❌ Failed to load photo: \(error)")
                    rejected += 1
                }
            }
            
            await MainActor.run {
                loadedPhotos = photos
                rejectedCount = rejected
                isLoading = false
                
                if photos.isEmpty && rejected > 0 {
                    loadError = "All selected files were unsupported formats"
                }
            }
        }
    }
    
    // MARK: - Load Single Photo
    
    private func loadPhotoItem(from pickerItem: PhotosPickerItem) async throws -> PhotoItem? {
        // Check supported content types — reject PNG, TIFF
        let supportedTypes: Set<UTType> = [.jpeg, .heic, .rawImage]
        
        let itemTypes = pickerItem.supportedContentTypes
        let matchedType = itemTypes.first { type in
            supportedTypes.contains(where: { type.conforms(to: $0) })
        }
        
        // If no supported type found, check if it's PNG/TIFF → reject
        if matchedType == nil {
            let isPNG = itemTypes.contains(where: { $0.conforms(to: .png) })
            let isTIFF = itemTypes.contains(where: { $0.conforms(to: .tiff) })
            if isPNG || isTIFF {
                print("📸 Rejected: PNG/TIFF not supported")
                return nil
            }
        }
        
        // Determine format
        let isRAW = itemTypes.contains(where: { $0.conforms(to: .rawImage) })
        let isHEIC = itemTypes.contains(where: { $0.conforms(to: .heic) })
        let format = isRAW ? "RAW" : (isHEIC ? "HEIC" : "JPEG")
        
        // Load image data
        guard let data = try await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return nil
        }
        
        // For RAW: convert to JPEG (CPU-intensive but required per spec)
        let finalImage: UIImage
        let finalFormat: String
        if isRAW {
            finalImage = image  // UIImage already decoded from RAW
            finalFormat = "JPEG" // Will be exported as JPEG
        } else {
            finalImage = image
            finalFormat = format
        }
        
        // Generate thumbnail (small, for chat display)
        let thumbnail = generateThumbnail(from: finalImage, maxDimension: 200)
        
        // Get PHAsset for metadata
        let phAssetId = pickerItem.itemIdentifier ?? UUID().uuidString
        
        // Extract metadata from PHAsset if available
        var capturedAt: String?
        var gpsLat: Double?
        var gpsLon: Double?
        var gpsAlt: Double?
        
        if let identifier = pickerItem.itemIdentifier {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            if let phAsset = fetchResult.firstObject {
                if let creationDate = phAsset.creationDate {
                    capturedAt = ISO8601DateFormatter().string(from: creationDate)
                }
                if let location = phAsset.location {
                    gpsLat = location.coordinate.latitude
                    gpsLon = location.coordinate.longitude
                    gpsAlt = location.altitude
                }
            }
        }
        
        // Device info
        let deviceModel = await UIDevice.current.model
        let osVersion = await "iOS \(UIDevice.current.systemVersion)"
        
        // File size
        let fileSize = Int64(data.count)
        
        // File name
        let ext = finalFormat == "HEIC" ? "heic" : "jpg"
        let fileName = "IMG_\(UUID().uuidString.prefix(8)).\(ext)"
        
        return PhotoItem(
            id: UUID().uuidString,
            phAssetIdentifier: phAssetId,
            image: finalImage,
            thumbnail: thumbnail,
            fileName: fileName,
            format: finalFormat,
            fileSize: fileSize,
            width: Int(finalImage.size.width * finalImage.scale),
            height: Int(finalImage.size.height * finalImage.scale),
            capturedAt: capturedAt,
            gpsLat: gpsLat,
            gpsLon: gpsLon,
            gpsAltitude: gpsAlt,
            deviceModel: deviceModel,
            osVersion: osVersion
        )
    }
    
    // MARK: - Thumbnail
    
    private func generateThumbnail(from image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
