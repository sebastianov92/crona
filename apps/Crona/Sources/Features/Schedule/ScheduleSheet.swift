import SwiftUI

struct ScheduleConfig: Equatable {
    var date = defaultScheduleDate()
    var recurrence: Recurrence = .NONE
    var recurrenceDays: Set<Int> = []
    var until: Date? = nil
    var timezone: String = TimeZone.current.identifier
    var randomDelay = false
}

/// Default al programar: mañana a las 9:00. Programar casi nunca es dentro de la próxima hora.
func defaultScheduleDate() -> Date {
    let cal = Calendar.current
    let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
}

/// Chips Mañana/Tarde/Noche reutilizables: fijan la fecha a la franja elegida (inline, sin abrir hoja).
/// Antes de la hora configurada → hoy; dentro del rango o después → mañana.
struct QuickHourChips: View {
    @Environment(SessionStore.self) private var session
    @Binding var date: Date

    private var hours: QuickHours { session.user?.quickHours ?? .default }

    var body: some View {
        HStack(spacing: 8) {
            chip("Mañana", icon: "sunrise", hours.morning)
            chip("Tarde", icon: "sun.max", hours.afternoon)
            chip("Noche", icon: "moon", hours.evening)
        }
    }

    /// Chips uniformes: mismo alto, una sola línea, ancho repartido en partes iguales.
    private func chip(_ label: String, icon: String, _ range: QuickRange) -> some View {
        let cal = Calendar.current
        let minuteOfDay = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let selected = minuteOfDay >= range.start && minuteOfDay <= max(range.start + 5, range.end)
        return Button {
            date = quickDate(range)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selected ? Theme.accent.opacity(0.22) : Color.gray.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Theme.accent : Color.gray.opacity(0.25), lineWidth: 1))
            .foregroundStyle(selected ? Theme.accent : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// Zonas comunes + la del dispositivo (lista completa sería inmanejable en un Picker)
let commonTimezones: [String] = {
    var zones = [
        TimeZone.current.identifier,
        "America/Guayaquil", "America/Bogota", "America/Lima", "America/Mexico_City",
        "America/New_York", "America/Chicago", "America/Los_Angeles",
        "America/Santiago", "America/Argentina/Buenos_Aires", "America/Sao_Paulo", "America/Caracas",
        "Europe/Madrid", "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Rome",
        "Asia/Tokyo", "Asia/Shanghai", "Asia/Dubai", "Australia/Sydney",
    ]
    var seen = Set<String>()
    zones = zones.filter { seen.insert($0).inserted }
    return zones
}()

func timezoneLabel(_ id: String) -> String {
    guard let tz = TimeZone(identifier: id) else { return id }
    let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
    let hours = tz.secondsFromGMT() / 3600
    let mins = abs(tz.secondsFromGMT() % 3600) / 60
    let offset = mins == 0 ? String(format: "%+d", hours) : String(format: "%+d:%02d", hours, mins)
    return "\(city) (GMT\(offset))"
}

struct ScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var config: ScheduleConfig

    private static let dayNames = [(1, "L"), (2, "M"), (3, "X"), (4, "J"), (5, "V"), (6, "S"), (7, "D")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QuickHourChips(date: $config.date)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Las horas de cada franja se configuran en Ajustes.")
                }

                Section("Elegir fecha…") {
                    DatePicker("Fecha y hora", selection: $config.date, in: Date().addingTimeInterval(120)...)
                        #if os(iOS)
                        .datePickerStyle(.graphical)
                        #endif
                }

                Section {
                    Picker("Zona horaria", selection: $config.timezone) {
                        ForEach(tzOptions, id: \.self) { Text(timezoneLabel($0)).tag($0) }
                    }
                } footer: {
                    if config.timezone != TimeZone.current.identifier {
                        Text("La hora elegida se interpreta en esa zona (ej. \"9:00 AM hora de \(timezoneLabel(config.timezone))\").")
                    }
                }

                Section("Repetir") {
                    Picker("Recurrencia", selection: $config.recurrence) {
                        Text("No se repite").tag(Recurrence.NONE)
                        Text("Todos los días").tag(Recurrence.DAILY)
                        Text("Semanal").tag(Recurrence.WEEKLY)
                        Text("Mensual").tag(Recurrence.MONTHLY)
                        Text("Cada año (cumpleaños)").tag(Recurrence.YEARLY)
                    }

                    if config.recurrence == .WEEKLY {
                        HStack(spacing: 6) {
                            ForEach(Self.dayNames, id: \.0) { (num, label) in
                                Button {
                                    if config.recurrenceDays.contains(num) { config.recurrenceDays.remove(num) }
                                    else { config.recurrenceDays.insert(num) }
                                } label: {
                                    Text(label)
                                        .font(.subheadline.bold())
                                        .frame(width: 32, height: 32)
                                        .background(config.recurrenceDays.contains(num) ? Theme.accent : Color.gray.opacity(0.15), in: Circle())
                                        .foregroundStyle(config.recurrenceDays.contains(num) ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if config.recurrenceDays.isEmpty {
                            Text("Elige al menos un día para que se repita.")
                                .font(.caption2).foregroundStyle(.red)
                        }
                    }

                    if config.recurrence != .NONE {
                        Toggle(isOn: $config.randomDelay) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Variar hora aleatoriamente")
                                Text("Cada envío se corre entre 1 y 5 min — evita el patrón exacto que detecta WhatsApp.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Hasta", isOn: .init(
                            get: { config.until != nil },
                            set: { config.until = $0 ? Calendar.current.date(byAdding: .month, value: 1, to: config.date) : nil }
                        ))
                        if config.until != nil {
                            DatePicker("Fecha final", selection: .init(
                                get: { config.until ?? config.date },
                                set: { config.until = $0 }
                            ), displayedComponents: [.date])
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Programar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
            // Al pasar a Semanal, preselecciona el día de la fecha (evita una recurrencia sin días
            // que nunca se dispara). El usuario puede ajustar.
            .onChange(of: config.recurrence) { _, rec in
                if rec == .WEEKLY && config.recurrenceDays.isEmpty {
                    config.recurrenceDays = [isoWeekday(config.date)]
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private var tzOptions: [String] {
        commonTimezones.contains(config.timezone) ? commonTimezones : [config.timezone] + commonTimezones
    }
}

/// Día de la semana en el esquema de la app (1=Lun … 7=Dom) a partir de una fecha.
func isoWeekday(_ date: Date) -> Int {
    let w = Calendar.current.component(.weekday, from: date) // 1=Dom … 7=Sáb
    return w == 1 ? 7 : w - 1
}
