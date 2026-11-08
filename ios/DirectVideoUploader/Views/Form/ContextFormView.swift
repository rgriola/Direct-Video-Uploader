// May 10, 2026 - 1:51pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Context form sheet — simplified "Add Details" form.
/// Layout: Header (thumbnail + filename + date) → Slug → Type → Description → Priority → Send

/// Identifies focusable fields for keyboard management.
private enum FormFocus: Hashable {
    case slug
    case description
}

struct ContextFormView: View {
    let fields: [FormField]
    let originalFileName: String?
    let capturedAt: String?
    let clipCount: Int?
    let duration: Int?
    let thumbnail: UIImage?
    var submitError: String?
    var errorRevision = 0
    var isSubmitting = false
    var submissionComplete = false
    var onSubmit: ([String: String]) async -> Void
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var formValues: [String: String] = [:]
    @State private var selectedPriority: String = "Low"
    @State private var hasAttemptedSubmit = false
    @State private var showCancelConfirm = false
    @State private var isStartingSubmission = false
    @State private var hasInitializedValues = false
    @FocusState private var focusedField: FormFocus?
    @AccessibilityFocusState private var accessibilityFocusedField: FormFocus?

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
        String(
            input.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        )
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
    private var isSending: Bool { isStartingSubmission || isSubmitting }

    var body: some View {
        NavigationStack {
            ZStack {
                // 50% lighter background — visually distinct from chat area
                Theme.formBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        formHeader

                        editableFields

                        // Error banner (shown if form submission failed)
                        if let error = submitError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.red)
                                Text(error)
                                    .font(Theme.font13Regular)
                                    .foregroundStyle(Theme.primaryText)
                            }
                            .padding(Theme.space12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.red.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        }

                        // Send button — disabled when required fields are empty
                        Button {
                            hasAttemptedSubmit = true
                            guard !isSending, !submissionComplete else { return }
                            guard canSubmit else {
                                let message = !isSlugValid
                                    ? "Slug is required." : "Description is required."
                                let invalidField: FormFocus = !isSlugValid ? .slug : .description
                                focusedField = invalidField
                                accessibilityFocusedField = invalidField
                                AccessibilityNotification.Announcement(message).post()
                                return
                            }
                            isStartingSubmission = true
                            let values = formValues
                            Task {
                                await onSubmit(values)
                                isStartingSubmission = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if isSending {
                                    ProgressView()
                                        .tint(Theme.white)
                                        .accessibilityHidden(true)
                                    Text("Sending")
                                        .font(Theme.font16Semibold)
                                } else if submissionComplete {
                                    Text("Sent")
                                        .font(Theme.font16Semibold)
                                    Image(systemName: "checkmark")
                                        .font(Theme.icon13)
                                        .accessibilityHidden(true)
                                } else {
                                    Text("Send")
                                        .font(Theme.font16Semibold)
                                    Image(systemName: "paperplane.fill")
                                        .font(Theme.icon13)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.space16)
                            .background(canSubmit ? Theme.blue : Theme.blue.opacity(0.35))
                            .foregroundStyle(Theme.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
                        }
                        .disabled(isSending || submissionComplete)
                        .padding(.top, 4)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Add Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if submissionComplete {
                            dismiss()
                        } else {
                            showCancelConfirm = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .accessibilityLabel("Close")
                    .disabled(isSending)
                }
            }
            .alert("Leave Details?", isPresented: $showCancelConfirm) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard and Leave", role: .destructive) {
                    onCancel?()
                    dismiss()
                }
            } message: {
                Text("Entered details will be lost. You can add details later from your Archive.")
            }
        }
        .interactiveDismissDisabled(isSending || !submissionComplete)
        .onAppear {
            guard !hasInitializedValues else { return }
            hasInitializedValues = true
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
        .onChange(of: isSending) { _, sending in
            if sending {
                AccessibilityNotification.Announcement("Sending details.").post()
            }
        }
        .onChange(of: errorRevision) { _, _ in
            if let error = submitError {
                AccessibilityNotification.Announcement(error).post()
            }
        }
        .task {
            // Auto-focus slug after the sheet animation settles; cancelled if the form closes first.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            focusedField = .slug
        }
    }

    // MARK: - Helpers

    private var formHeader: some View {
        HStack(spacing: 14) {
            if let thumb = thumbnail {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusSm)
                    .fill(Theme.glassOverlay)
                    .frame(width: 80, height: 60)
                    .overlay {
                        Image(systemName: "video.fill")
                            .font(Theme.font20Bold)
                            .foregroundStyle(Theme.tertiaryText)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(clipCount ?? 1) Clip")
                        .font(Theme.font16Semibold)
                        .foregroundStyle(Theme.primaryText)
                    if let duration, duration > 0 {
                        Text("· \(DVUDateFormatting.duration(duration))")
                            .font(Theme.font16Semibold)
                            .foregroundStyle(Theme.primaryText)
                    }
                }
                if let originalFileName {
                    Text(originalFileName)
                        .font(Theme.font11Regular)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                if let capturedAt {
                    Text("🕐 \(DVUDateFormatting.longDate(capturedAt))")
                        .font(Theme.font11Regular)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.glassOverlay)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
    }

    private func priorityButton(_ level: String) -> some View {
        let isSelected = selectedPriority == level
        return Button {
            selectedPriority = level
            formValues["priority"] = level == "Med" ? "Medium" : level
        } label: {
            Text(level)
                .font(Theme.font13Regular.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Theme.blue.opacity(0.25) : Theme.glassOverlay)
                .foregroundStyle(isSelected ? Theme.blue : Theme.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .strokeBorder(isSelected ? Theme.blue : Color.clear, lineWidth: 1.5))
                .tapTarget()
        }
        .accessibilityLabel("\(level == "Med" ? "Medium" : level) priority")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var editableFields: some View {
        VStack(spacing: 16) {
            slugField
            typeField
            descriptionField
            fieldSection(label: "PRIORITY") {
                HStack(spacing: 8) {
                    ForEach(["Low", "Med", "High", "Critical"], id: \.self) { level in
                        priorityButton(level)
                    }
                }
            }
        }
        .disabled(isSending || submissionComplete)
    }

    private var slugField: some View {
        fieldSection(label: "SLUG", required: true) {
            TextField(
                "",
                text: Binding(
                    get: { formValues["slug"] ?? "" },
                    set: { formValues["slug"] = sanitize($0) }
                )
            )
            .font(Theme.font16Regular)
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, Theme.space16)
            .padding(.vertical, 14)
            .background(Theme.glassOverlay)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .strokeBorder(
                        hasAttemptedSubmit && !isSlugValid ? Theme.red : Color.clear,
                        lineWidth: 1.5))
            .focused($focusedField, equals: .slug)
            .accessibilityFocused($accessibilityFocusedField, equals: .slug)
            .accessibilityLabel("Slug, required")
            if hasAttemptedSubmit && !isSlugValid {
                Text("Slug is required.")
                    .font(Theme.font11Regular)
                    .foregroundStyle(Theme.red)
            }
        }
    }

    private var typeField: some View {
        fieldSection(label: "TYPE") {
            Menu {
                Button("Raw") { formValues["type"] = "Raw" }
                Button("Cut") { formValues["type"] = "Cut" }
            } label: {
                HStack {
                    Text(formValues["type"] ?? "Raw")
                        .font(Theme.font16Regular)
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(Theme.icon13)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityLabel("Type")
                .accessibilityValue(formValues["type"] ?? "Raw")
                .padding(.horizontal, Theme.space16)
                .padding(.vertical, 14)
                .background(Theme.glassOverlay)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            }
        }
    }

    private var descriptionField: some View {
        fieldSection(label: "DESCRIPTION", required: true) {
            TextEditor(
                text: Binding(
                    get: { formValues["description"] ?? "" },
                    set: { formValues["description"] = sanitizeDescription($0) }
                )
            )
            .font(Theme.font16Regular)
            .foregroundStyle(Theme.primaryText)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 80)
            .padding(Theme.space12)
            .background(Theme.glassOverlay)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .strokeBorder(
                        hasAttemptedSubmit && !isDescriptionValid ? Theme.red : Color.clear,
                        lineWidth: 1.5))
            .focused($focusedField, equals: .description)
            .accessibilityFocused($accessibilityFocusedField, equals: .description)
            .accessibilityLabel("Description, required")
            if hasAttemptedSubmit && !isDescriptionValid {
                Text("Description is required.")
                    .font(Theme.font11Regular)
                    .foregroundStyle(Theme.red)
            }
        }
    }

    /// Section label — shows red asterisk for required fields
    private func fieldSection<Content: View>(
        label: String, required: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(label)
                    .font(Theme.font11Semibold)
                    .foregroundStyle(Theme.secondaryText)
                    .tracking(0.8)
                if required {
                    Text("*")
                        .font(Theme.font13Semibold)
                        .foregroundStyle(Theme.red)
                }
            }
            .accessibilityHidden(true)
            content()
        }
    }
}
