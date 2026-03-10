import SwiftUI

/// Archive list — shows all of the user's past uploads in an expandable list.
struct ArchiveListView: View {
    @Environment(AuthService.self) private var auth
    
    @State private var assets: [Asset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archive")
                            .font(Theme.titleFont)
                            .foregroundStyle(.white)
                        Text("\(assets.count) upload\(assets.count == 1 ? "" : "s")")
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
                } else if assets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("📦")
                            .font(Theme.emptyEmojiFont)
                        Text("No uploads yet")
                            .font(Theme.emptyStateFont)
                            .foregroundStyle(.white)
                        Text("Your completed uploads will appear here.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(assets) { asset in
                                ArchiveRowView(asset: asset)
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
