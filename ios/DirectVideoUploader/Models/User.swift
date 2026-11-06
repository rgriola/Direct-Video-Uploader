import Foundation

// MARK: - User

nonisolated struct User: Codable, Identifiable, Sendable {
    let id: String
    let phoneNumber: String
    let name: String
    let email: String?
    let team: String?
    let status: String?
    let companyCode: String?
    let companyName: String?
}

// MARK: - Auth

nonisolated struct LoginRequest: Codable, Sendable {
    let phoneNumber: String
    let pin: String
    let companyCode: String
}

nonisolated struct LoginResponse: Codable, Sendable {
    let token: String
    let user: User
}

nonisolated struct MeResponse: Codable, Sendable {
    let user: User
}
