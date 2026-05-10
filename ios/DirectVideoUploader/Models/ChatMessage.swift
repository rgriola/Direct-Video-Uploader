// May 10, 2026 - 8:18pm - GitHub Copilot (GPT-5.3-Codex)
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

    /// Display text resolved with a per-message stable seed.
    /// This keeps randomized catalog variants fixed for each bubble.
    var displayText: String {
        let stableSeed = [id, createdAt ?? "", messageType.rawValue, direction.rawValue].joined(
            separator: "|")
        return MessageCatalog.resolve(content: content, stableSeed: stableSeed)
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
    case systemNote = "SYSTEM_NOTE"
    case muxReady = "MUX_READY"
}

// MARK: - Message Content

/// Flexible content container — matches the JSON `content` field from the server.
struct MessageContent: Codable {
    let text: String?
    let code: String?
    let params: [String: String]?
    let fallbackText: String?
    let schemaVersion: Int?
    let fileName: String?
    let slug: String?
    let mediasourceId: String?
    let mediasourceUrl: String?
    let formFields: [FormField]?
    let channel: String?
    let mention: String?
    let thumbnailUrl: String?

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
    let fileSize: String?
    let hasRichMeta: Bool?

    init(
        text: String? = nil,
        code: String? = nil,
        params: [String: String]? = nil,
        fallbackText: String? = nil,
        schemaVersion: Int? = nil,
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
        fileSize: String? = nil,
        hasRichMeta: Bool? = nil
    ) {
        self.text = text
        self.code = code
        self.params = params
        self.fallbackText = fallbackText
        self.schemaVersion = schemaVersion
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
        self.fileSize = fileSize
        self.hasRichMeta = hasRichMeta
    }

    /// Display text for the chat bubble
    var displayText: String {
        MessageCatalog.resolve(content: self, stableSeed: nil)
    }
}

// MARK: - Form Field

struct FormField: Codable, Identifiable {
    let id: String
    let label: String
    let type: String  // "text", "select", "textarea"
    let value: String?
    let options: [String]?
    let required: Bool?
    let isReadOnly: Bool?

    init(
        id: String = UUID().uuidString, label: String, type: String = "text", value: String? = nil,
        options: [String]? = nil, required: Bool? = nil, isReadOnly: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.value = value
        self.options = options
        self.required = required
        self.isReadOnly = isReadOnly
    }
}

extension FormField {
    /// Default form fields for video uploads — shared between ChatViewModel and ArchiveRowView.
    static func defaultVideoFields() -> [FormField] {
        [
            FormField(id: "slug", label: "Slug / Title", type: "text", value: nil),
            FormField(id: "type", label: "Content Type", type: "select", options: ["Raw", "Cut"]),
            FormField(id: "description", label: "Description / Notes", type: "textarea"),
            FormField(
                id: "priority", label: "Priority", type: "select", value: "Low",
                options: ["Low", "Medium", "High", "Critical"]),
        ]
    }
}

// MARK: - Messages Response

struct MessagesResponse: Codable {
    let messages: [ChatMessage]
}
