import SwiftUI

/// Context form sheet — simplified "Add Details" form.
/// Layout: Header (thumbnail + filename + date) → Slug → Type → Description → Priority → Send
struct ContextFormView: View {
    let fields: [FormField]
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    let thumbnail: UIImage?
    var submitError: String?
    var onSubmit: ([String: String]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var formValues: [String: String] = [:]
    @State private var selectedPriority: String = "Low"
    @State private var hasAttemptedSubmit = false
    
    /// Only letters, numbers, dashes, and periods allowed
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-. "))
    
    /// Sanitize input: strip anything not in the allowed set
    private func sanitize(_ input: String) -> String {
        String(input.unicodeScalars.filter { Self.allowedCharacters.contains($0) })
    }
    
    private var isSlugValid: Bool {
        let slug = formValues["slug"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return !slug.isEmpty
    }
    
    private var isDescriptionValid: Bool {
        let desc = formValues["description"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return !desc.isEmpty
    }
    
    private var canSubmit: Bool { isSlugValid && isDescriptionValid }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 50% lighter background — visually distinct from chat area
                Color(hex: "1A2544").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Clip header — thumbnail + filename + date
                        HStack(spacing: 14) {
                            // Video thumbnail (real image or placeholder)
                            if let thumb = thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 80, height: 60)
                                    .overlay {
                                        Image(systemName: "video.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
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
                            // Slug (required)
                            fieldSection(label: "SLUG", required: true) {
                                TextField("", text: Binding(
                                    get: { formValues["slug"] ?? "" },
                                    set: { formValues["slug"] = sanitize($0) }
                                ))
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            hasAttemptedSubmit && !isSlugValid ? Color.red : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
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
                            
                            // Description (required)
                            fieldSection(label: "DESCRIPTION", required: true) {
                                TextEditor(text: Binding(
                                    get: { formValues["description"] ?? "" },
                                    set: { formValues["description"] = sanitize($0) }
                                ))
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80)
                                .padding(12)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            hasAttemptedSubmit && !isDescriptionValid ? Color.red : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
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
                        
                        // Error banner (shown if form submission failed)
                        if let error = submitError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color(hex: "FF453A"))
                                Text(error)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: "FF453A").opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        // Send button — disabled when required fields are empty
                        Button {
                            hasAttemptedSubmit = true
                            guard canSubmit else { return }
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
                            .background(canSubmit ? Color(hex: "007AFF") : Color(hex: "007AFF").opacity(0.35))
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
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            // Initialize form values from field defaults — slug starts empty
            for field in fields {
                // Skip slug prefill — always start clean
                if field.id == "slug" { continue }
                if let value = field.value {
                    formValues[field.id] = value
                }
            }
            // Default type
            if formValues["type"] == nil { formValues["type"] = "Raw" }
            // Default priority to Low
            if formValues["priority"] == nil { formValues["priority"] = "Low" }
        }
    }
    
    // MARK: - Helpers
    
    /// Section label — shows red asterisk for required fields
    private func fieldSection<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(0.8)
                if required {
                    Text("*")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
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
