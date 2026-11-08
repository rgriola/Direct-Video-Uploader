import Foundation
import Testing
@testable import DirectVideoUploader

struct ModelDecodingTests {
    @Test
    func userDecodesServerFieldsAndIgnoresAdditionalRole() throws {
        let json = """
            {
              "user": {
                "id": "user-1",
                "phoneNumber": "5550100",
                "name": "Reporter",
                "email": "reporter@example.com",
                "team": "Field",
                "status": "ACTIVE",
                "companyCode": "NEWS",
                "companyName": "News Org",
                "role": "SUPER_ADMIN",
                "createdAt": "2026-05-09T00:00:00.000Z"
              }
            }
            """

        let response = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8))

        #expect(response.user.id == "user-1")
        #expect(response.user.phoneNumber == "5550100")
        #expect(response.user.name == "Reporter")
        #expect(response.user.email == "reporter@example.com")
        #expect(response.user.team == "Field")
        #expect(response.user.companyCode == "NEWS")
        #expect(response.user.companyName == "News Org")
    }

    @Test
    func userAllowsMissingOptionalFieldsButRequiresIdentity() throws {
        let minimal = #"{"id":"user-1","phoneNumber":"5550100","name":"Reporter"}"#
        let user = try JSONDecoder().decode(User.self, from: Data(minimal.utf8))

        #expect(user.email == nil)
        #expect(user.team == nil)
        #expect(user.companyCode == nil)

        let missingPhone = #"{"id":"user-1","name":"Reporter"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(User.self, from: Data(missingPhone.utf8))
        }
    }

    @Test
    func assetDetailDecodesClipMetadataAndFormResponse() throws {
        let json = """
            {
              "asset": {
                "id": "asset-1",
                "mediasourceId": "100000001",
                "mediasourceUrl": "/clips/100000001",
                "originalFileName": "field-report.mp4",
                "status": "READY",
                "clipCount": 1,
                "totalDuration": 12,
                "createdAt": "2026-05-10T01:02:03.000Z",
                "user": {"id": "user-1", "name": "Reporter", "phoneNumber": "5550100"},
                "clips": [{
                  "id": "clip-1",
                  "assetId": "asset-1",
                  "clipIndex": 0,
                  "muxAssetId": "mux-asset-1",
                  "muxUploadId": "mux-upload-1",
                  "muxPlaybackId": "mux-playback-1",
                  "originalFileName": "field-report.mp4",
                  "duration": 12,
                  "fileSize": "123456789",
                  "transcript": "Hello",
                  "transcriptSegments": [{
                    "word": "Hello",
                    "start": 0.0,
                    "end": 0.5,
                    "confidence": 0.9
                  }],
                  "status": "READY",
                  "thumbnailUrl": "https://example.com/thumbnail.png"
                }],
                "formResponse": {
                  "id": "form-1",
                  "assetId": "asset-1",
                  "slug": "field-report",
                  "type": "Raw",
                  "priority": "HIGH"
                }
              }
            }
            """

        let response = try JSONDecoder().decode(AssetDetailResponse.self, from: Data(json.utf8))
        let asset = response.asset
        let clip = try #require(asset.clips?.first)
        let segment = try #require(clip.transcriptSegments?.first)

        #expect(asset.id == "asset-1")
        #expect(asset.status == .ready)
        #expect(asset.mediasourceId == "100000001")
        #expect(asset.clipCount == 1)
        #expect(asset.user?.name == "Reporter")
        #expect(asset.formResponse?.slug == "field-report")
        #expect(asset.formResponse?.priority == "HIGH")
        #expect(clip.id == "clip-1")
        #expect(clip.assetId == "asset-1")
        #expect(clip.muxAssetId == "mux-asset-1")
        #expect(clip.muxUploadId == "mux-upload-1")
        #expect(clip.muxPlaybackId == "mux-playback-1")
        #expect(clip.fileSize == "123456789")
        #expect(clip.duration == 12)
        #expect(clip.thumbnailUrl == "https://example.com/thumbnail.png")
        #expect(segment.word == "Hello")
        #expect(segment.start == 0.0)
        #expect(segment.end == 0.5)
        #expect(segment.confidence == 0.9)
    }

    @Test
    func newAssetAllowsAbsentRelationships() throws {
        let json = #"{"asset":{"id":"asset-1","status":"UPLOADING"}}"#
        let response = try JSONDecoder().decode(CreateAssetResponse.self, from: Data(json.utf8))

        #expect(response.asset.status == .uploading)
        #expect(response.asset.clips == nil)
        #expect(response.asset.formResponse == nil)
        #expect(response.asset.user == nil)
    }

    @Test
    func unknownAssetStatusFailsDecoding() {
        let json = #"{"id":"asset-1","status":"UNKNOWN"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Asset.self, from: Data(json.utf8))
        }
    }

    @Test
    func assetModerationDefaultsLegacyResponsesAndFailsClosedForUnknownValues() throws {
        let legacy = try JSONDecoder().decode(
            Asset.self, from: Data(#"{"id":"legacy","status":"READY"}"#.utf8))
        #expect(legacy.moderation == nil)
        #expect(legacy.permitsMediaActions)

        for (rawValue, expected) in [
            ("ACTIVE", AssetModeration.active),
            ("PAUSED", .paused),
            ("FLAGGED_FOR_REMOVAL", .flaggedForRemoval),
            ("REMOVED", .removed),
        ] {
            let json = #"{"id":"asset-1","status":"READY","moderation":"\#(rawValue)"}"#
            let asset = try JSONDecoder().decode(Asset.self, from: Data(json.utf8))
            #expect(asset.moderation == expected)
            #expect(asset.permitsMediaActions == (expected == .active))
        }

        let unknown = try JSONDecoder().decode(
            Asset.self,
            from: Data(#"{"id":"asset-1","status":"READY","moderation":"NEW_STATE"}"#.utf8))
        #expect(unknown.moderation == .unknown)
        #expect(!unknown.permitsMediaActions)
    }

    @Test
    func messageHistoryDecodesIncomingAndOutgoingPayloads() throws {
        let json = """
            {
              "messages": [
                {
                  "id": "message-in",
                  "userId": "user-1",
                  "assetId": "asset-1",
                  "direction": "INCOMING",
                  "messageType": "FORM_REQUEST",
                  "content": {
                    "code": "WS_FORM_CONFIRMED",
                    "schemaVersion": 1,
                    "formFields": [{
                      "id": "slug",
                      "label": "Slug / Title",
                      "type": "text",
                      "required": true
                    }]
                  },
                  "createdAt": "2026-05-10T01:02:03.000Z"
                },
                {
                  "id": "message-out",
                  "direction": "OUTGOING",
                  "messageType": "VIDEO",
                  "content": {"fileName": "field-report.mp4"}
                }
              ]
            }
            """

        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        try #require(response.messages.count == 2)

        let incoming = response.messages[0]
        let outgoing = response.messages[1]
        #expect(!incoming.isOutgoing)
        #expect(incoming.messageType == .formRequest)
        #expect(incoming.content.code == "WS_FORM_CONFIRMED")
        #expect(incoming.content.formFields?.first?.required == true)
        #expect(outgoing.isOutgoing)
        #expect(outgoing.messageType == .video)
        #expect(outgoing.content.fileName == "field-report.mp4")
    }

    @Test
    func unknownMessageTypeFailsDecoding() {
        let json = """
            {"id":"message-1","direction":"INCOMING","messageType":"UNKNOWN","content":{}}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        }
    }
}
