import SwiftUI

/// Configura las franjas de los botones rápidos Mañana/Tarde/Noche:
/// hora exacta (se envía +1..5 min aleatorios) o rango (hora aleatoria dentro del rango).
struct QuickHoursSettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var hours: QuickHours = .default
    @State private var loaded = false

    var body: some View {
        Form {
            periodSection("Mañana", icon: "sunrise", range: binding(\.morning))
            periodSection("Tarde", icon: "sun.max", range: binding(\.afternoon))
            periodSection("Noche", icon: "moon", range: binding(\.evening))

            Section {
            } footer: {
                Text("Al usar un botón rápido: si aún no llega la hora configurada se programa para hoy; si ya pasó (o estás dentro del rango), para mañana.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Horarios rápidos")
        .onAppear {
            if !loaded {
                hours = session.user?.quickHours ?? .default
                loaded = true
            }
        }
        .onChange(of: hours) { _, h in
            guard loaded else { return }
            Task { session.user = try? await APIClient.shared.patchMe(quickHours: h) }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<QuickHours, QuickRange>) -> Binding<QuickRange> {
        Binding(get: { hours[keyPath: keyPath] }, set: { hours[keyPath: keyPath] = $0 })
    }

    private func periodSection(_ title: String, icon: String, range: Binding<QuickRange>) -> some View {
        Section {
            Picker(selection: Binding(
                get: { range.wrappedValue.start == range.wrappedValue.end ? 0 : 1 },
                set: { mode in
                    var r = range.wrappedValue
                    r.end = mode == 0 ? r.start : min(r.start + 60, 1439)
                    range.wrappedValue = r
                }
            )) {
                Text("Hora exacta").tag(0)
                Text("Rango").tag(1)
            } label: {
                Label(title, systemImage: icon)
            }

            DatePicker(range.wrappedValue.start == range.wrappedValue.end ? "Hora" : "Desde",
                       selection: minuteBinding(range, \.start),
                       displayedComponents: [.hourAndMinute])

            if range.wrappedValue.start != range.wrappedValue.end {
                DatePicker("Hasta", selection: minuteBinding(range, \.end), displayedComponents: [.hourAndMinute])
            }
        } footer: {
            Text(range.wrappedValue.start == range.wrappedValue.end
                 ? "Se envía entre 1 y 5 minutos después de esa hora."
                 : "Se envía a una hora aleatoria dentro del rango.")
        }
    }

    /// Minutos del día ⇄ Date (solo se usa la hora)
    private func minuteBinding(_ range: Binding<QuickRange>, _ keyPath: WritableKeyPath<QuickRange, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = range.wrappedValue[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let cal = Calendar.current
                let m = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
                var r = range.wrappedValue
                let exact = r.start == r.end
                r[keyPath: keyPath] = m
                // hora exacta: mover start mueve end; rango: mantener start ≤ end
                if exact && keyPath == \.start { r.end = m }
                if r.end < r.start {
                    if keyPath == \.start { r.end = r.start } else { r.start = r.end }
                }
                range.wrappedValue = r
            }
        )
    }
}
