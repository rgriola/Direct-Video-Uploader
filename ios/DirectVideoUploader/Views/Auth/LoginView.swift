import SwiftUI

/// Login screen — phone number + PIN, matching the dark aesthetic.
struct LoginView: View {
    @Environment(AuthService.self) private var auth
    
    @State private var phoneNumber = ""
    @State private var pin = ""
    @State private var showServerEditor = false
    @State private var serverURLDraft = ""
    @FocusState private var focusedField: Field?
    
    enum Field { case phone, pin, serverURL }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.black, Theme.deepBg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                // Logo & branding
                VStack(spacing: 12) {
                    Text("🎬")
                        .font(Theme.loginEmojiFont)
                    
                    Text("Fixer")
                        .font(Theme.loginTitleFont)
                        .foregroundStyle(.white)
                    
                    Text("Send. Confirm. Done.")
                        .font(Theme.loginTaglineFont)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 4)
                }
                .padding(.bottom, 24)
                
                // Server URL indicator — tap to edit (above form so keyboard doesn't cover it)
                serverURLIndicator
                    .padding(.bottom, 24)
                
                // Form
                VStack(spacing: 16) {
                    // Phone number
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PHONE NUMBER")
                            .font(Theme.labelFont)
                            .foregroundStyle(.white.opacity(0.5))
                            .tracking(0.8)
                        
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundStyle(.white.opacity(0.4))
                                .font(Theme.iconFont)
                            
                            TextField("5055034455", text: $phoneNumber)
                                .keyboardType(.numberPad)
                                .textContentType(.telephoneNumber)
                                .focused($focusedField, equals: .phone)
                                .foregroundStyle(.white)
                                .font(Theme.loginFieldFont)
                                .onChange(of: phoneNumber) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 15 { phoneNumber = String(digits.prefix(15)) }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(focusedField == .phone ? Color.blue : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    
                    // PIN
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PIN")
                            .font(Theme.labelFont)
                            .foregroundStyle(.white.opacity(0.5))
                            .tracking(0.8)
                        
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.white.opacity(0.4))
                                .font(Theme.iconFont)
                            
                            SecureField("1234", text: $pin)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .pin)
                                .foregroundStyle(.white)
                                .font(Theme.loginFieldFont)
                                .onChange(of: pin) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 8 { pin = String(digits.prefix(8)) }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(focusedField == .pin ? Color.blue : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 32)
                
                // Error message
                if let error = auth.errorMessage {
                    Text(error)
                        .font(Theme.captionFont)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }
                
                // Login button
                Button {
                    Task { await login() }
                } label: {
                    HStack {
                        if auth.isLoading {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Text("Sign In")
                                .font(Theme.loginButtonFont)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [Theme.bubbleBlueHi, Theme.bubbleBlueLo],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(auth.isLoading || phoneNumber.isEmpty || pin.isEmpty)
                .opacity(phoneNumber.isEmpty || pin.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                
                Spacer()
                
                // Demo hint
                VStack(spacing: 4) {
                    Text("Demo Account")
                        .font(Theme.loginHintFont)
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Phone: 5055034455 · PIN: 1234")
                        .font(Theme.loginHintMonoFont)
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(.bottom, 32)
            }
        }
        .onSubmit {
            if focusedField == .phone {
                focusedField = .pin
            } else {
                Task { await login() }
            }
        }
    }
    
    // MARK: - Server URL Indicator
    
    private var serverURLIndicator: some View {
        VStack(spacing: 8) {
            if showServerEditor {
                // Editable URL field
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(Theme.timestampFont)
                    
            TextField("http://192.168.0.111:3000", text: $serverURLDraft)
                        .font(Theme.loginServerFont)
                        .foregroundStyle(.white.opacity(0.7))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .serverURL)
                    
                    Button {
                        ServerConfig.setServerURL(serverURLDraft)
                        showServerEditor = false
                        focusedField = nil
                    } label: {
                        Text("Save")
                            .font(Theme.labelFont)
                            .foregroundStyle(.blue)
                    }
                    
                    if ServerConfig.hasCustomURL {
                        Button {
                            ServerConfig.resetServerURL()
                            serverURLDraft = ServerConfig.currentURLString
                            showServerEditor = false
                            focusedField = nil
                        } label: {
                            Text("Reset")
                                .font(Theme.labelFont)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 32)
            } else {
                // Compact display — tap to edit
                Button {
                    serverURLDraft = ServerConfig.currentURLString
                    showServerEditor = true
                    focusedField = .serverURL
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green.opacity(0.6))
                            .frame(width: 6, height: 6)
                        
                        Image(systemName: "server.rack")
                            .font(Theme.iconTinyFont)
                        
                        Text(ServerConfig.currentURLString)
                            .font(Theme.loginServerFont)
                        
                        if ServerConfig.hasCustomURL {
                            Text("(custom)")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
    }
    
    private func login() async {
        focusedField = nil
        do {
            try await auth.login(phoneNumber: phoneNumber, pin: pin)
        } catch {
            auth.errorMessage = error.localizedDescription
        }
    }
}
