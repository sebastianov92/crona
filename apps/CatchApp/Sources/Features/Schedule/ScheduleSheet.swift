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
                Section("Chips rápidos") {
                    HStack(spacing: 8) {
                        quickChip("En 1 hora", Date().addingTimeInterval(3600))
                        quickChip("Esta noche 8:00 PM", tonight8PM())
                        quickChip("Mañana 9:00 AM", tomorrow9AM())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

    private func quickChip(_ label: String, _ date: Date) -> some View {
        Button(label) { config.date = date }
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
