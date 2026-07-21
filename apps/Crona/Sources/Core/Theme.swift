import SwiftUI

enum Theme {
    static let accent = Color(red: 0.145, green: 0.827, blue: 0.400)   // #25D366
    static let avatarSize: CGFloat = 44          // 40 en el sidebar de macOS
}

// MARK: - Formato de fechas (§18.6): locale es, zona del dispositivo

func scheduleLabel(_ date: Date) -> String {
    let cal = Calendar.current
    let df = DateFormatter()
    df.locale = Locale(identifier: "es")
    df.dateFormat = "h:mm a"
    let hora = df.string(from: date)

    if cal.isDateInToday(date) { return "Hoy \(hora)" }
    if cal.isDateInTomorrow(date) { return "Mañana \(hora)" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 99
    if days > 0 && days < 7 {
        df.dateFormat = "EEE h:mm a"
        return df.string(from: date)
    }
    df.dateFormat = "d MMM h:mm a"
    return df.string(from: date)
}

// MARK: - Iconos de estado (§9.3)

extension ScheduleStatus {
    var systemImage: String {
        switch self {
        case .ACTIVE: return "clock"
        case .PAUSED: return "pause.circle"
        case .COMPLETED: return "checkmark"
        case .CANCELLED: return "xmark.circle"
        case .FAILED: return "exclamationmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .FAILED: return .red
        case .PAUSED, .CANCELLED: return .secondary
        default: return Theme.accent
        }
    }
    var label: String {
        switch self {
        case .ACTIVE: return "Programado"
        case .PAUSED: return "Pausado"
        case .COMPLETED: return "Completado"
        case .CANCELLED: return "Cancelado"
        case .FAILED: return "Fallido"
        }
    }
}

extension LogStatus {
    var systemImage: String {
        switch self {
        case .SENDING: return "clock"
        case .SENT: return "checkmark"
        case .DELIVERED: return "checkmark.circle"
        case .READ: return "checkmark.circle.fill"
        case .FAILED: return "exclamationmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .READ: return .blue
        case .FAILED: return .red
        default: return .secondary
        }
    }
    var label: String {
        switch self {
        case .SENDING: return "Enviando…"
        case .SENT: return "Enviado"
        case .DELIVERED: return "Entregado"
        case .READ: return "Leído"
        case .FAILED: return "Fallido"
        }
    }
}

extension MessageType {
    var preview: String {
        switch self {
        case .TEXT: return ""
        case .IMAGE: return "📷 Foto"
        case .VIDEO: return "🎥 Video"
        case .DOCUMENT: return "📄 Documento"
        case .AUDIO: return "🎤 Nota de voz"
        }
    }
}

func messagePreview(type: MessageType, body: String?) -> String {
    if type == .TEXT { return body ?? "" }
    let caption = (body ?? "").trimmingCharacters(in: .whitespaces)
    return caption.isEmpty ? type.preview : "\(type.preview) · \(caption)"
}

let recurrenceIcon = "arrow.trianglehead.2.clockwise"

// MARK: - Avatar con iniciales de fallback

struct AvatarView: View {
    let name: String
    let pictureUrl: String?
    var size: CGFloat = Theme.avatarSize

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var body: some View {
        Group {
            if let pictureUrl, let url = URL(string: pictureUrl) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.25))
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }
}
