import Foundation

// MARK: - User

struct User: Codable, Identifiable, Sendable {
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

struct LoginRequest: Codable, Sendable {
    let phoneNumber: String
    let pin: String
    let companyCode: String
}

struct LoginResponse: Codable, Sendable {
    let token: String
    let user: User
}

struct MeResponse: Codable, Sendable {
    let user: User
}
