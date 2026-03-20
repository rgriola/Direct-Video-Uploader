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
    case muxReady = "MUX_READY"
}

// MARK: - Message Content

/// Flexible content container — matches the JSON `content` field from the server.
struct MessageContent: Codable {
    let text: String?
    let fileName: String?
    let slug: String?
    let mediasourceId: String?
    let mediasourceUrl: String?
    let formFields: [FormField]?
    let channel: String?
    let mention: String?
    let thumbnailUrl: String?
    
    // Form response data (populated on confirmation bubbles)
    let formType: String?
    let formDescription: String?
    let formPriority: String?
    
    // Metadata summary fields (populated on upload response / form request bubbles)
    let originalFileName: String?
    let userName: String?
    let clipCount: Int?
    let duration: Int?
    let gpsLat: Double?
    let gpsLon: Double?
    let capturedAt: String?
    let codec: String?
    let resolution: String?
    let hasRichMeta: Bool?
    
    init(
        text: String? = nil,
        fileName: String? = nil,
        slug: String? = nil,
        mediasourceId: String? = nil,
        mediasourceUrl: String? = nil,
        formFields: [FormField]? = nil,
        channel: String? = nil,
        mention: String? = nil,
        thumbnailUrl: String? = nil,
        originalFileName: String? = nil,
        userName: String? = nil,
        clipCount: Int? = nil,
        duration: Int? = nil,
        gpsLat: Double? = nil,
        gpsLon: Double? = nil,
        capturedAt: String? = nil,
        codec: String? = nil,
        resolution: String? = nil,
        hasRichMeta: Bool? = nil,
        formType: String? = nil,
        formDescription: String? = nil,
        formPriority: String? = nil
    ) {
        self.text = text
        self.fileName = fileName
        self.slug = slug
        self.mediasourceId = mediasourceId
        self.mediasourceUrl = mediasourceUrl
        self.formFields = formFields
        self.channel = channel
        self.mention = mention
        self.thumbnailUrl = thumbnailUrl
        self.originalFileName = originalFileName
        self.userName = userName
        self.clipCount = clipCount
        self.duration = duration
        self.gpsLat = gpsLat
        self.gpsLon = gpsLon
        self.capturedAt = capturedAt
        self.codec = codec
        self.resolution = resolution
        self.hasRichMeta = hasRichMeta
        self.formType = formType
        self.formDescription = formDescription
        self.formPriority = formPriority
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
