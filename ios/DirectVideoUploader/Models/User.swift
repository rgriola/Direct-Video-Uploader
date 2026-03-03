import Foundation

// MARK: - User

struct User: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    let name: String
    let email: String?
    let team: String?
    let status: String?
}

// MARK: - Auth

struct LoginRequest: Codable {
    let phoneNumber: String
    let pin: String
}

struct LoginResponse: Codable {
    let token: String
    let user: User
}

struct MeResponse: Codable {
    let user: User
}
