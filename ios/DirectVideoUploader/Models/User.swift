// May 12, 2026 - 3:52pm - GitHub Copilot (GPT-5.3-Codex)
import Foundation

// MARK: - User

struct User: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    let name: String
    let email: String?
    let team: String?
    let role: String?
    let status: String?
    let companyCode: String?
    let companyName: String?
}

// MARK: - Auth

struct LoginRequest: Codable {
    let phoneNumber: String
    let pin: String
    let companyCode: String
}

struct LoginResponse: Codable {
    let token: String
    let user: User
}

struct MeResponse: Codable {
    let user: User
}

struct SSOConfigResponse: Codable {
    let companyCode: String
    let companyName: String?
    let ssoEnabled: Bool
    let samlEntityId: String?
    let samlMetadataUrl: String?
    let samlAttributeMapping: [String: String]?
    let startUrl: String?
}
