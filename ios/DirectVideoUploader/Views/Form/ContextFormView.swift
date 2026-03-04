import SwiftUI

/// Context form sheet — simplified "Add Details" form.
/// Layout: Header (filename + date) → Slug → Type → Description → Priority → Send
struct ContextFormView: View {
    let fields: [FormField]
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    var onSubmit: ([String: String]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var formValues: [String: String] = [:]
    @State private var selectedPriority: String = "Medium"
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0A0E1A").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Clip header — thumbnail area + filename + date
                        HStack(spacing: 14) {
                            // Thumbnail placeholder
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 80, height: 60)
                                .overlay {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                // Clip count + duration
                                HStack(spacing: 4) {
                                    let clips = clipCount ?? 1
                                    Text("\(clips) Clip")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    if let dur = duration, dur > 0 {
                                        Text("· \(formatDuration(dur))")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                
                                // Original filename
                                if let name = originalFileName {
                                    Text(name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                
                                // Captured date
                                if let dateStr = capturedAt {
                                    Text("🕐 \(formatDate(dateStr))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // Editable fields
                        VStack(spacing: 16) {
                            // Slug
                            fieldSection(label: "SLUG") {
                                TextField("Slug name", text: Binding(
                                    get: { formValues["slug"] ?? "" },
                                    set: { formValues["slug"] = $0 }
                                ))
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            
                            // Type
                            fieldSection(label: "TYPE") {
                                Menu {
                                    Button("Raw") { formValues["type"] = "Raw" }
                                    Button("Cut") { formValues["type"] = "Cut" }
                                } label: {
                                    HStack {
                                        Text(formValues["type"] ?? "Raw")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            
                            // Description
                            fieldSection(label: "DESCRIPTION") {
                                TextEditor(text: Binding(
                                    get: { formValues["description"] ?? "" },
                                    set: { formValues["description"] = $0 }
                                ))
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80)
                                .padding(12)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            
                            // Priority (segmented)
                            fieldSection(label: "PRIORITY") {
                                HStack(spacing: 8) {
                                    ForEach(["Low", "Med", "High", "Critical"], id: \.self) { level in
                                        let isSelected = selectedPriority == level
                                        Button {
                                            selectedPriority = level
                                            let fullName = level == "Med" ? "Medium" : level
                                            formValues["priority"] = fullName
                                        } label: {
                                            Text(level)
                                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(
                                                    isSelected
                                                        ? Color(hex: "007AFF").opacity(0.25)
                                                        : Color.white.opacity(0.06)
                                                )
                                                .foregroundStyle(
                                                    isSelected
                                                        ? Color(hex: "007AFF")
                                                        : .white.opacity(0.5)
                                                )
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .strokeBorder(
                                                            isSelected ? Color(hex: "007AFF") : Color.clear,
                                                            lineWidth: 1.5
                                                        )
                                                )
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Send button
                        Button {
                            onSubmit(formValues)
                        } label: {
                            HStack(spacing: 6) {
                                Text("Send")
                                    .font(.system(size: 16, weight: .semibold))
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 14))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "007AFF"))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.top, 4)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Add Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .onAppear {
            // Initialize form values from field defaults
            for field in fields {
                if let value = field.value {
                    formValues[field.id] = value
                }
            }
            // Default type
            if formValues["type"] == nil { formValues["type"] = "Raw" }
            if formValues["priority"] == nil { formValues["priority"] = "Medium" }
        }
    }
    
    // MARK: - Helpers
    
    private func fieldSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .tracking(0.8)
            content()
        }
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let min = seconds / 60
        let sec = seconds % 60
        return String(format: "%d:%02d", min, sec)
    }
    
    private func formatDate(_ isoString: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return isoString
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}
