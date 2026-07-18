import SwiftUI

struct ScheduleConfig: Equatable {
    var date = Date().addingTimeInterval(3600)
    var recurrence: Recurrence = .NONE
    var recurrenceDays: Set<Int> = []
    var until: Date? = nil
}

struct ScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var config: ScheduleConfig

    private static let dayNames = [(1, "L"), (2, "M"), (3, "X"), (4, "J"), (5, "V"), (6, "S"), (7, "D")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        quickChip("En 1 hora", icon: "clock", Date().addingTimeInterval(3600))
                        quickChip("Hoy 8 PM", icon: "moon", tonight8PM())
                        quickChip("Mañana 9 AM", icon: "sunrise", tomorrow9AM())
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                Section("Elegir fecha…") {
                    DatePicker("Fecha y hora", selection: $config.date, in: Date().addingTimeInterval(120)...)
                        #if os(iOS)
                        .datePickerStyle(.graphical)
                        #endif
                }

                Section("Repetir") {
                    Picker("Recurrencia", selection: $config.recurrence) {
                        Text("No se repite").tag(Recurrence.NONE)
                        Text("Todos los días").tag(Recurrence.DAILY)
                        Text("Semanal").tag(Recurrence.WEEKLY)
                        Text("Mensual").tag(Recurrence.MONTHLY)
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
                    }

                    if config.recurrence != .NONE {
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
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    /// Chips uniformes: mismo alto, una sola línea, ancho repartido en partes iguales.
    private func quickChip(_ label: String, icon: String, _ date: Date) -> some View {
        let selected = abs(config.date.timeIntervalSince(date)) < 60
        return Button {
            config.date = date
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

    private func tonight8PM() -> Date {
        let cal = Calendar.current
        let today8 = cal.date(bySettingHour: 20, minute: 0, second: 0, of: .now)!
        return today8 > .now ? today8 : cal.date(byAdding: .day, value: 1, to: today8)!
    }

    private func tomorrow9AM() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: .now)!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}
