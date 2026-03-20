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
    var onCancel: (() -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @State private var formValues: [String: String] = [:]
    @State private var selectedPriority: String = "Low"
    @State private var hasAttemptedSubmit = false
    @State private var showCancelConfirm = false
    
    /// Only letters, numbers, dashes, and periods allowed
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-. "))
    
    /// Sanitize input: strip anything not in the allowed set (for slug)
    private func sanitize(_ input: String) -> String {
        String(input.unicodeScalars.filter { Self.allowedCharacters.contains($0) })
    }

    /// Sanitize free-text description: strip only null bytes and non-printable control
    /// characters. Preserves newlines, punctuation, and all printable Unicode.
    private func sanitizeDescription(_ input: String) -> String {
        String(input.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" })
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
                Theme.formBg.ignoresSafeArea()
                
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
                                            .font(Theme.titleFont)
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                // Clip count + duration
                                HStack(spacing: 4) {
                                    let clips = clipCount ?? 1
                                    Text("\(clips) Clip")
                                        .font(Theme.formClipFont)
                                        .foregroundStyle(.white)
                                    if let dur = duration, dur > 0 {
                                        Text("· \(DVUDateFormatting.duration(dur))")
                                            .font(Theme.formClipFont)
                                            .foregroundStyle(.white)
                                    }
                                }
                                
                                // Original filename
                                if let name = originalFileName {
                                    Text(name)
                                        .font(Theme.headerStatusFont)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                
                                // Captured date
                                if let dateStr = capturedAt {
                                    Text("🕐 \(DVUDateFormatting.longDate(dateStr))")
                                        .font(Theme.headerStatusFont)
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
                                .font(Theme.formFieldFont)
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
                                            .font(Theme.formFieldFont)
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(Theme.iconSmallFont)
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
                                    set: { formValues["description"] = sanitizeDescription($0) }
                                ))
                                .font(Theme.formFieldFont)
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
                                                .font(Theme.formPriorityFont.weight(isSelected ? .semibold : .regular))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(
                                                    isSelected
                                                        ? Theme.blue.opacity(0.25)
                                                        : Color.white.opacity(0.06)
                                                )
                                                .foregroundStyle(
                                                    isSelected
                                                        ? Theme.blue
                                                        : .white.opacity(0.5)
                                                )
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .strokeBorder(
                                                            isSelected ? Theme.blue : Color.clear,
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
                                    .foregroundStyle(Theme.red)
                                Text(error)
                                    .font(Theme.formErrorFont)
                                    .foregroundStyle(.white)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.red.opacity(0.15))
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
                                    .font(Theme.loginButtonFont)
                                Image(systemName: "paperplane.fill")
                                    .font(Theme.iconFont)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canSubmit ? Theme.blue : Theme.blue.opacity(0.35))
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
                    Button {
                        if canSubmit {
                            dismiss()
                        } else {
                            showCancelConfirm = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .alert("Skip Details?", isPresented: $showCancelConfirm) {
                Button("Keep Editing", role: .cancel) { }
                Button("Skip for Now", role: .destructive) {
                    onCancel?()
                    dismiss()
                }
            } message: {
                Text("Your video is still uploading. You can add details later from your Archive.")
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
                    .font(Theme.labelFont)
                    .foregroundStyle(.white.opacity(0.3))
                    .tracking(0.8)
                if required {
                    Text("*")
                        .font(Theme.captionBoldFont)
                        .foregroundStyle(.red)
                }
            }
            content()
        }
    }
}
