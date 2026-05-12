// May 12, 2026 - 3:35pm - GitHub Copilot (GPT-5.3-Codex)
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
