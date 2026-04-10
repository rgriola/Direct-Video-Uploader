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
                        .foregroundStyle(Theme.white.opacity(0.8))
                }
                .padding(.bottom, Theme.space24)
                
                // Server URL indicator — tap to edit (above form so keyboard doesn't cover it)
                serverURLIndicator
                    .padding(.bottom, Theme.space24)
                
                // Form
                VStack(spacing: Theme.space16) {
                    // Phone number
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        Text("PHONE NUMBER")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.white.opacity(0.5))
                            .tracking(0.8)
                        
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundStyle(Theme.white.opacity(0.4))
                                .font(Theme.icon13)
                            
                            TextField("5055034455", text: $phoneNumber)
                                .keyboardType(.numberPad)
                                .textContentType(.telephoneNumber)
                                .focused($focusedField, equals: .phone)
                                .foregroundStyle(Theme.white)
                                .font(Theme.font16Medium)
                                .onChange(of: phoneNumber) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 10 { phoneNumber = String(digits.prefix(10)) }
                                }
                        }
                        .padding(.horizontal, Theme.space16)
                        .padding(.vertical, 14)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .stroke(focusedField == .phone ? Theme.blue : Theme.glassBorder, lineWidth: 1)
                        )
                    }
                    
                    // PIN
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        Text("PIN")
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.white.opacity(0.5))
                            .tracking(0.8)
                        
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(Theme.white.opacity(0.4))
                                .font(Theme.icon13)
                            
                            SecureField("1234", text: $pin)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .pin)
                                .foregroundStyle(Theme.white)
                                .font(Theme.font16Medium)
                                .onChange(of: pin) { _, new in
                                    let digits = new.filter { $0.isNumber }
                                    if digits != new || new.count > 8 { pin = String(digits.prefix(8)) }
                                }
                        }
                        .padding(.horizontal, Theme.space16)
                        .padding(.vertical, 14)
                        .background(Theme.glassOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .stroke(focusedField == .pin ? Theme.blue : Theme.glassBorder, lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, Theme.space32)
                
                // Error message
                if let error = auth.errorMessage {
                    Text(error)
                        .font(Theme.font13Regular)
                        .foregroundStyle(Theme.red)
                        .padding(.top, Theme.space12)
                }
                
                // Login button
                Button {
                    Task { await login() }
                } label: {
                    HStack {
                        if auth.isLoading {
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
                .disabled(auth.isLoading || phoneNumber.isEmpty || pin.isEmpty)
                .opacity(phoneNumber.isEmpty || pin.isEmpty ? 0.5 : 1)
                .padding(.horizontal, Theme.space32)
                .padding(.top, 28)
                
                Spacer()
                
                // Demo hint
                VStack(spacing: Theme.space4) {
                    Text("Demo Account")
                        .font(Theme.font11Semibold)
                        .foregroundStyle(Theme.white.opacity(0.3))
                    Text("Phone: 5055034455 · PIN: 1234")
                        .font(Theme.mono11Medium)
                        .foregroundStyle(Theme.white.opacity(0.25))
                }
                .padding(.bottom, Theme.space32)
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
        VStack(spacing: Theme.space8) {
            #if DEBUG
            if showServerEditor {
                // Editable URL field
                HStack(spacing: Theme.space8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Theme.white.opacity(0.4))
                        .font(Theme.icon11)
                    
            TextField("http://192.168.0.111:3000", text: $serverURLDraft)
                        .font(Theme.mono11Medium)
                        .foregroundStyle(Theme.white.opacity(0.7))
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
                            .font(Theme.font11Semibold)
                            .foregroundStyle(Theme.blue)
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
                        }
                    }
                }
                .padding(.horizontal, Theme.space12)
                .padding(.vertical, 10)
                .background(Theme.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
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
                    .foregroundStyle(Theme.white.opacity(0.25))
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
            .foregroundStyle(Theme.white.opacity(0.25))
            #endif
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
