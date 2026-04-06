import SwiftUI

/// Archive list — shows all of the user's past uploads in an expandable list.
struct ArchiveListView: View {
    @Environment(AuthService.self) private var auth
    
    @State private var assets: [Asset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    /// Only show uploads from the last 7 days
    private var recentAssets: [Asset] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return assets.filter { asset in
            guard let dateStr = asset.createdAt,
                  let date = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
            else { return true } // keep if unparseable
            return date >= cutoff
        }
    }
    
    /// Assets stuck in PROCESSING for over 5 minutes
    private var stuckCount: Int {
        let cutoff5min = Date().addingTimeInterval(-300)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return recentAssets.filter { asset in
            guard asset.status == .processing else { return false }
            guard let dateStr = asset.createdAt,
                  let created = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
            else { return true }
            return created < cutoff5min
        }.count
    }
    
    var body: some View {
        ZStack {
            // view background
            Theme.screenGradient.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archive")
                            .font(Theme.titleFont)
                            .foregroundStyle(.white)
                        Text("\(recentAssets.count) upload\(recentAssets.count == 1 ? "" : "s") (7 days)")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    
                    Button {
                        Task { await fetchAssets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.iconHeaderFont)
                            .foregroundStyle(Theme.tint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.darkBg)
                
                Divider().background(Theme.separator)
                
                // Stuck uploads banner
                if stuckCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.red)
                        Text("\(stuckCount) upload\(stuckCount == 1 ? "" : "s") failed — tap to expand and re-upload")
                            .font(Theme.captionFont)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.red.opacity(0.15))
                }
                
                // Content
                if isLoading && assets.isEmpty {
                    Spacer()
                    ProgressView()
                        .tint(.white)
                    Spacer()
                } else if let error = errorMessage, assets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("⚠️")
                            .font(Theme.emojiLargeFont)
                        Text(error)
                            .font(Theme.formErrorFont)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await fetchAssets() }
                        }
                        .font(Theme.formErrorFont)
                        .foregroundStyle(Theme.tint)
                    }
                    .padding()
                    Spacer()
                } else if recentAssets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("📦")
                            .font(Theme.emptyEmojiFont)
                        Text("No recent uploads")
                            .font(Theme.emptyStateFont)
                            .foregroundStyle(.white)
                        Text("No uploads in the last 7 days.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(recentAssets) { asset in
                                ArchiveRowView(asset: asset, onFormSubmitted: {
                                    Task { await fetchAssets() }
                                })
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task {
            await fetchAssets()
        }
    }
    
    // MARK: - Fetch
    
    private func fetchAssets() async {
        guard let token = auth.token else {
            errorMessage = "Not authenticated"
            return
        }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        var request = URLRequest(url: ServerConfig.myAssetsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Server error"
                return
            }
            let decoded = try JSONDecoder().decode(MyAssetsResponse.self, from: data)
            assets = decoded.assets
        } catch {
            errorMessage = "Could not load uploads: \(error.localizedDescription)"
        }
    }
}
