// May 10, 2026 - 1:51pm - GitHub Copilot (GPT-5.3-Codex)
import SwiftUI

/// Login screen — phone number + PIN, matching the dark aesthetic.
struct LoginView: View {
    @Environment(AuthService.self) private var auth

    @State private var companyCode = ""
    @State private var phoneNumber = ""
    @State private var pin = ""
    @State private var showServerEditor = false
    @State private var serverURLDraft = ""
    @State private var isStartingLogin = false
    @FocusState private var focusedField: Field?

    enum Field { case companyCode, phone, pin, serverURL }
    private var isLoggingIn: Bool { isStartingLogin || auth.isLoading }

    var body: some View {
        ZStack {
            // Background gradient
            Theme.loginGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo & branding
                VStack(spacing: Theme.space12) {
                    Image("FixerLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)

                    Text("Send. Confirm. Done.")
                        .font(Theme.font13Medium)
                        .foregroundStyle(Theme.primaryText)
                }
                .padding(.bottom, Theme.space24)

                // Server URL indicator — tap to edit (above form so keyboard doesn't cover it)
                serverURLIndicator
                    .padding(.bottom, Theme.space24)
                    .disabled(isLoggingIn)

                // Form
                VStack(spacing: Theme.space16) {
                    // Company Code
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        Text("COMPANY CODE")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.secondaryText)
                            .tracking(0.8)

                        HStack {
                            Image(systemName: "building.2.fill")
                                .foregroundStyle(Theme.secondaryText)
                                .font(Theme.icon13)

                            TextField("ABC or ABCD", text: $companyCode)
                                .textContentType(.organizationName)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .companyCode)
                                .foregroundStyle(Theme.primaryText)
                                .font(Theme.font16Medium)
                                .onChange(of: companyCode) { _, new in
                                    let letters = new.filter { $0.isLetter }
                                    if letters != new || new.count > 4 {
                                        companyCode = String(letters.prefix(4))
                                    }
                                }
                        }
                        .padding(.horizontal, Theme.space16)
                        .padding(.vertical, 14)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .stroke(
                                    focusedField == .companyCode ? Theme.blue : Theme.glassBorder,
                                    lineWidth: 1)
                        )
                    }

                    // Phone number
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        Text("PHONE NUMBER")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.secondaryText)
                            .tracking(0.8)

                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundStyle(Theme.secondaryText)
                                .font(Theme.icon13)

                            TextField("5055034455", text: $phoneNumber)
                                .keyboardType(.numberPad)
                                .textContentType(.telephoneNumber)
                                .focused($focusedField, equals: .phone)
                                .foregroundStyle(Theme.primaryText)
                                .font(Theme.font16Medium)
                                .onChange(of: phoneNumber) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 10 {
                                        phoneNumber = String(digits.prefix(10))
                                    }
                                }
                        }
                        .padding(.horizontal, Theme.space16)
                        .padding(.vertical, 14)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .stroke(
                                    focusedField == .phone ? Theme.blue : Theme.glassBorder,
                                    lineWidth: 1)
                        )
                    }

                    // PIN
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        Text("PIN")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.secondaryText)
                            .tracking(0.8)

                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(Theme.secondaryText)
                                .font(Theme.icon13)

                            SecureField("1234", text: $pin)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .pin)
                                .foregroundStyle(Theme.primaryText)
                                .font(Theme.font16Medium)
                                .onChange(of: pin) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 8 {
                                        pin = String(digits.prefix(8))
                                    }
                                }
                        }
                        .padding(.horizontal, Theme.space16)
                        .padding(.vertical, 14)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .stroke(
                                    focusedField == .pin ? Theme.blue : Theme.glassBorder,
                                    lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, Theme.space32)
                .disabled(isLoggingIn)

                // Error message
                if let error = auth.errorMessage {
                    Text(error)
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.red)
                        .padding(.top, Theme.space12)
                }

                // Login button
                Button {
                    startLogin()
                } label: {
                    HStack {
                        if isLoggingIn {
                            ProgressView()
                                .tint(Theme.white)
                                .scaleEffect(0.8)
                        } else {
                            Text("Sign In")
                                .font(Theme.font16Semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.space16)
                    .background(Theme.buttonGradient)
                    .foregroundStyle(Theme.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
                }
                .disabled(
                    isLoggingIn || showServerEditor
                        || companyCode.isEmpty || phoneNumber.isEmpty || pin.isEmpty
                )
                .opacity(
                    showServerEditor || companyCode.isEmpty || phoneNumber.isEmpty || pin.isEmpty
                        ? 0.5 : 1)
                .padding(.horizontal, Theme.space32)
                .padding(.top, 28)

                Spacer()

                // Demo hint
                VStack(spacing: Theme.space4) {
                    Text("Built With Love")
                        .font(Theme.font11Semibold)
                        .foregroundStyle(Theme.secondaryText)
                    Text("")
                        .font(Theme.mono11Medium)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.bottom, Theme.space32)
            }
        }
        .onTapGesture {
            focusedField = nil
        }
        .onSubmit {
            guard !isLoggingIn else { return }
            if showServerEditor {
                if focusedField == .serverURL { saveServerURL() }
            } else if focusedField == .companyCode {
                focusedField = .phone
            } else if focusedField == .phone {
                focusedField = .pin
            } else {
                startLogin()
            }
        }
    }

    // MARK: - Server URL Indicator

    private var serverURLIndicator: some View {
        VStack(spacing: Theme.space8) {
            #if DEBUG
                if showServerEditor {
                    // Editable URL field
                    HStack(spacing: Theme.space8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Theme.secondaryText)
                            .font(Theme.icon11)

                        TextField("http://192.168.0.111:3000", text: $serverURLDraft)
                            .font(Theme.mono11Medium)
                            .foregroundStyle(Theme.primaryText)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .serverURL)

                        Button {
                            saveServerURL()
                        } label: {
                            Text("Save")
                                .font(Theme.font11Semibold)
                                .foregroundStyle(Theme.blue)
                                .tapTarget()
                        }

                        if ServerConfig.hasCustomURL {
                            Button {
                                ServerConfig.resetServerURL()
                                serverURLDraft = ServerConfig.currentURLString
                                showServerEditor = false
                                focusedField = nil
                            } label: {
                                Text("Reset")
                                    .font(Theme.font11Semibold)
                                    .foregroundStyle(Theme.red.opacity(0.7))
                                    .tapTarget()
                            }
                        }
                        Button {
                            showServerEditor = false
                            focusedField = nil
                        } label: {
                            Text("Cancel")
                                .font(Theme.font11Semibold)
                                .foregroundStyle(Theme.secondaryText)
                                .tapTarget()
                        }
                    }
                    .padding(.horizontal, Theme.space12)
                    .padding(.vertical, 10)
                    .background(Theme.glassOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .padding(.horizontal, Theme.space32)
                    Text("Don't include passwords or tokens in the server URL.")
                        .font(Theme.font11Regular)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, Theme.space32)
                } else {
                    // Compact display — tap to edit
                    Button {
                        serverURLDraft = ServerConfig.currentURLString
                        showServerEditor = true
                        focusedField = .serverURL
                    } label: {
                        HStack(spacing: Theme.space4) {
                            Circle()
                                .fill(Theme.green.opacity(0.6))
                                .frame(width: 6, height: 6)

                            Image(systemName: "server.rack")
                                .font(Theme.icon11)

                            Text(ServerConfig.currentURLString)
                                .font(Theme.mono11Medium)

                            if ServerConfig.hasCustomURL {
                                Text("(custom)")
                                    .font(Theme.font11Medium)
                            }
                        }
                        .foregroundStyle(Theme.secondaryText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            #else
                // Release: show production URL (read-only)
                HStack(spacing: Theme.space4) {
                    Circle()
                        .fill(Theme.green.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Image(systemName: "server.rack")
                        .font(Theme.icon11)
                    Text(ServerConfig.currentURLString)
                        .font(Theme.mono11Medium)
                }
                .foregroundStyle(Theme.secondaryText)
            #endif
        }
    }

    private func saveServerURL() {
        ServerConfig.setServerURL(serverURLDraft)
        showServerEditor = false
        focusedField = nil
    }

    private func startLogin() {
        guard !isLoggingIn, !showServerEditor,
              !companyCode.isEmpty, !phoneNumber.isEmpty, !pin.isEmpty else { return }
        isStartingLogin = true
        let phone = phoneNumber
        let code = companyCode
        let submittedPIN = pin
        Task {
            defer { isStartingLogin = false }
            await login(phone: phone, pin: submittedPIN, companyCode: code)
        }
    }

    private func login(phone: String, pin: String, companyCode: String) async {
        focusedField = nil
        let generation = auth.sessionGeneration
        do {
            try await auth.login(phoneNumber: phone, pin: pin, companyCode: companyCode)
        } catch {
            if auth.sessionGeneration == generation {
                auth.errorMessage = error.localizedDescription
            }
        }
    }
}
