import SwiftUI

/// Context form sheet — presented when the server requests clip metadata.
struct ContextFormView: View {
    let fields: [FormField]
    var onSubmit: ([String: String]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var formValues: [String: String] = [:]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0A0E1A").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 8) {
                            Text("📋")
                                .font(.system(size: 40))
                            Text("Asset Context")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Help the newsroom with a few details")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        
                        // Metadata section (read-only fields)
                        let readOnlyFields = fields.filter { $0.isReadOnly == true }
                        if !readOnlyFields.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("VIDEO DETAILS")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .tracking(0.8)
                                
                                VStack(spacing: 1) {
                                    ForEach(readOnlyFields) { field in
                                        HStack {
                                            Text(field.label)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.white.opacity(0.5))
                                                .frame(width: 90, alignment: .leading)
                                            Text(field.value ?? "—")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.8))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(Color.white.opacity(0.04))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        
                        // Editable fields section
                        let editableFields = fields.filter { $0.isReadOnly != true }
                        if !editableFields.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("YOUR INPUT")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .tracking(0.8)
                                
                                ForEach(editableFields) { field in
                                    formField(for: field)
                                }
                            }
                        }
                        
                        // If no fields from server, show defaults
                        if fields.isEmpty {
                            defaultFields
                        }
                        
                        // Submit button
                        Button {
                            onSubmit(formValues)
                        } label: {
                            Text("Submit")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color(hex: "30D158"))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.top, 8)
                    }
                    .padding(24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
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
        }
    }
    
    // MARK: - Form Field Views
    
    @ViewBuilder
    private func formField(for field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(field.isReadOnly == true ? 0.35 : 0.5))
                    .tracking(0.8)
                
                if field.required == true {
                    Text("*")
                        .foregroundStyle(Color(hex: "FF453A"))
                }
            }
            
            // Read-only fields render as plain display text
            if field.isReadOnly == true {
                Text(field.value ?? "—")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if field.type == "select", let options = field.options {
                // Picker
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            formValues[field.id] = option
                        }
                    }
                } label: {
                    HStack {
                        Text(formValues[field.id] ?? "Select...")
                            .font(.system(size: 15))
                            .foregroundStyle(
                                formValues[field.id] != nil ? .white : .white.opacity(0.4)
                            )
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
            } else if field.type == "textarea" {
                // Multi-line text
                TextEditor(text: Binding(
                    get: { formValues[field.id] ?? "" },
                    set: { formValues[field.id] = $0 }
                ))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                // Single-line text
                TextField(field.label, text: Binding(
                    get: { formValues[field.id] ?? "" },
                    set: { formValues[field.id] = $0 }
                ))
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    // MARK: - Default Fields (when server doesn't specify)
    
    private var defaultFields: some View {
        VStack(spacing: 20) {
            formField(for: FormField(id: "slug", label: "Slug / Title", type: "text"))
            formField(for: FormField(
                id: "type",
                label: "Content Type",
                type: "select",
                options: ["Raw", "Interview", "Standup", "B-Roll", "Live Shot", "Other"]
            ))
            formField(for: FormField(id: "description", label: "Description / Notes", type: "textarea"))
            formField(for: FormField(
                id: "priority",
                label: "Priority",
                type: "select",
                options: ["Low", "Medium", "High", "Critical"]
            ))
        }
    }
}
