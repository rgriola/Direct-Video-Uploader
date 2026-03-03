import Foundation
import SwiftUI

// MARK: - Chat Message

struct ChatMessage: Codable, Identifiable {
    let id: String
    let userId: String?
    let assetId: String?
    let direction: MessageDirection
    let messageType: MessageType
    let content: MessageContent
    let createdAt: String?
    
    /// Whether this message is from the user (outgoing) or server (incoming)
    var isOutgoing: Bool {
        direction == .outgoing
    }
}

enum MessageDirection: String, Codable {
    case outgoing = "OUTGOING"
    case incoming = "INCOMING"
}

enum MessageType: String, Codable {
    case video = "VIDEO"
    case formRequest = "FORM_REQUEST"
    case formSubmitted = "FORM_SUBMITTED"
    case confirmation = "CONFIRMATION"
    case slackPost = "SLACK_POST"
    case text = "TEXT"
    case greeting = "GREETING"
}

// MARK: - Message Content

/// Flexible content container — matches the JSON `content` field from the server.
struct MessageContent: Codable {
    let text: String?
    let fileName: String?
    let mediasourceId: String?
    let mediasourceUrl: String?
    let formFields: [FormField]?
    let channel: String?
    let mention: String?
    
    init(
        text: String? = nil,
        fileName: String? = nil,
        mediasourceId: String? = nil,
        mediasourceUrl: String? = nil,
        formFields: [FormField]? = nil,
        channel: String? = nil,
        mention: String? = nil
    ) {
        self.text = text
        self.fileName = fileName
        self.mediasourceId = mediasourceId
        self.mediasourceUrl = mediasourceUrl
        self.formFields = formFields
        self.channel = channel
        self.mention = mention
    }
    
    /// Display text for the chat bubble
    var displayText: String {
        text ?? fileName ?? "..."
    }
}

// MARK: - Form Field

struct FormField: Codable, Identifiable {
    let id: String
    let label: String
    let type: String     // "text", "select", "textarea"
    let value: String?
    let options: [String]?
    let required: Bool?
    let isReadOnly: Bool?
    
    init(id: String = UUID().uuidString, label: String, type: String = "text", value: String? = nil, options: [String]? = nil, required: Bool? = nil, isReadOnly: Bool? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.value = value
        self.options = options
        self.required = required
        self.isReadOnly = isReadOnly
    }
}

// MARK: - Messages Response

struct MessagesResponse: Codable {
    let messages: [ChatMessage]
}
