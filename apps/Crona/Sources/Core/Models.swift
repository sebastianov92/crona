import Foundation

// MARK: - Enums (espejo exacto de SPEC §15)

enum Role: String, Codable, CaseIterable { case ADMIN, USER }
enum InstanceStatus: String, Codable, CaseIterable { case CREATED, CONNECTING, CONNECTED, DISCONNECTED }
enum RecipientKind: String, Codable, CaseIterable { case CONTACT, GROUP }
enum MessageType: String, Codable, CaseIterable { case TEXT, IMAGE, VIDEO, DOCUMENT }
enum Recurrence: String, Codable, CaseIterable { case NONE, DAILY, WEEKLY, MONTHLY, YEARLY }
enum AutoReplyAction: String, Codable, CaseIterable { case REPLY, NOTIFY }
enum ScheduleStatus: String, Codable, CaseIterable { case ACTIVE, PAUSED, COMPLETED, CANCELLED, FAILED }
enum LogStatus: String, Codable, CaseIterable { case SENDING, SENT, DELIVERED, READ, FAILED }

// MARK: - Structs

struct User: Identifiable, Codable, Hashable {
    let id: String
    let email: String
    var name: String
    let role: Role
    var ntfyTopic: String?
    var notifyOnSent: Bool
    let createdAt: Date
}

struct AuthResponse: Codable, Hashable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct RefreshResponse: Codable, Hashable {
    let accessToken: String
    let refreshToken: String
}

struct Instance: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let instanceName: String
    var phoneNumber: String?
    var profilePicUrl: String?
    var status: InstanceStatus
    var lastConnectedAt: Date?
    let createdAt: Date
}

struct CreateInstanceResponse: Codable, Hashable {
    let instance: Instance
    let qrBase64: String?
    let pairingCode: String?
}

struct QRResponse: Codable, Hashable {
    let qrBase64: String?
    let pairingCode: String?
}

struct SyncResult: Codable, Hashable {
    let contacts: Int
    let groups: Int
}

struct Recipient: Identifiable, Codable, Hashable {
    let id: String
    let jid: String
    let displayName: String
    let pictureUrl: String?
    let kind: RecipientKind
    let phoneNumber: String?
}

struct MediaUpload: Codable, Hashable {
    let mediaId: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
}

struct ScheduledMessage: Identifiable, Codable, Hashable {
    let id: String
    let instanceId: String
    let recipientJid: String
    let recipientName: String
    let recipientKind: RecipientKind
    let recipientPictureUrl: String?
    let type: MessageType
    var body: String?
    var mediaId: String?
    var timezone: String
    var scheduledAt: Date
    var recurrence: Recurrence
    var recurrenceDays: [Int]
    var recurrenceUntil: Date?
    var nextRunAt: Date
    var status: ScheduleStatus
    var attempts: Int
    var lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

struct MessageLog: Identifiable, Codable, Hashable {
    let id: String
    let scheduledMessageId: String
    let runAt: Date
    let status: LogStatus
    let evolutionMessageId: String?
    let remoteJid: String
    let error: String?
    let sentAt: Date?
    let deliveredAt: Date?
    let readAt: Date?
}

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: String
    let scheduledMessageId: String
    let runAt: Date
    let status: LogStatus
    let recipientName: String
    let recipientKind: RecipientKind
    let recipientPictureUrl: String?
    let type: MessageType
    let body: String?
    let mediaId: String?
    let error: String?
}

struct MessageDetail: Codable, Hashable {
    let message: ScheduledMessage
    let logs: [MessageLog]
}

struct Paginated<T: Codable & Hashable>: Codable, Hashable {
    let items: [T]
    let nextCursor: String?
}

struct AdminSettings: Codable, Hashable {
    var evolutionBaseUrl: String
    var evolutionGlobalApiKeySet: Bool
    var ntfyBaseUrl: String
}

struct SettingsTestResult: Codable, Hashable {
    let ok: Bool
    let version: String
}

struct InviteResponse: Codable, Hashable {
    let code: String
    let expiresAt: Date
}

struct OkResponse: Codable, Hashable {
    let ok: Bool
}

struct HealthResponse: Codable, Hashable {
    let ok: Bool
    let service: String
}

struct AutoReply: Identifiable, Codable, Hashable {
    let id: String
    let instanceId: String
    var action: AutoReplyAction
    var keyword: String?
    var replyText: String?
    var activeFromHour: Int?
    var activeToHour: Int?
    var timezone: String
    var cooldownMinutes: Int
    var enabled: Bool
    let createdAt: Date
}

struct AutoReplyBody: Codable {
    var instanceId: String
    var action: AutoReplyAction
    var keyword: String?
    var replyText: String?
    var activeFromHour: Int?
    var activeToHour: Int?
    var timezone: String
    var cooldownMinutes: Int
    var enabled: Bool
}

// MARK: - Cuerpos de request

struct RecipientInput: Codable, Hashable {
    let jid: String
    let name: String
    let kind: RecipientKind
    let pictureUrl: String?
}

struct CreateMessageBody: Codable, Hashable {
    var instanceId: String
    var recipient: RecipientInput
    var type: MessageType
    var body: String?
    var mediaId: String?
    var scheduledAt: Date
    var timezone: String
    var recurrence: Recurrence
    var recurrenceDays: [Int]
    var recurrenceUntil: Date?
}

struct PatchMessageBody: Codable, Hashable {
    var body: String?
    var mediaId: String?
    var scheduledAt: Date?
    var timezone: String?
    var recurrence: Recurrence?
    var recurrenceDays: [Int]?
    var recurrenceUntil: Date?
    var status: ScheduleStatus?
}
