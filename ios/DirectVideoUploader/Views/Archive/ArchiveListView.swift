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
        return assets.filter { asset in
            guard let dateStr = asset.createdAt,
                  let date = DVUDateFormatting.parseISO(dateStr)
            else { return true } // keep if unparseable
            return date >= cutoff
        }
    }
    
    private var stuckCount: Int {
        let cutoff5min = Date().addingTimeInterval(-300)
        return recentAssets.filter { asset in
            guard asset.status == .processing else { return false }
            guard let dateStr = asset.createdAt,
                  let created = DVUDateFormatting.parseISO(dateStr)
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
                            .font(Theme.font20Bold)
                            .foregroundStyle(Theme.white)
                        Text("\(recentAssets.count) upload\(recentAssets.count == 1 ? "" : "s") (7 days)")
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    
                    Button {
                        Task { await fetchAssets() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.icon20)
                            .foregroundStyle(Theme.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.black)
                
                Divider().background(Theme.separator)
                
                // Stuck uploads banner
                if stuckCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.red)
                        Text("\(stuckCount) upload\(stuckCount == 1 ? "" : "s") failed — tap to expand and re-upload")
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.white)
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
                        .tint(Theme.white)
                    Spacer()
                } else if let error = errorMessage, assets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("⚠️")
                            .font(Theme.display44)
                        Text(error)
                            .font(Theme.font13Regular)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await fetchAssets() }
                        }
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.blue)
                    }
                    .padding()
                    Spacer()
                } else if recentAssets.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("📦")
                            .font(Theme.display64)
                        Text("No recent uploads")
                            .font(Theme.font16Medium)
                            .foregroundStyle(Theme.white)
                        Text("No uploads in the last 7 days.")
                            .font(Theme.font13Regular)
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
        guard auth.isAuthenticated else {
            errorMessage = "Not authenticated"
            return
        }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        let request = auth.authenticatedRequest(for: ServerConfig.myAssetsURL)
        
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
