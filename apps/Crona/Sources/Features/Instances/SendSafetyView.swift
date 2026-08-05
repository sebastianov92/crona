import SwiftUI

/// Envelope anti-baneo de una instancia: caudal por hora, tope diario, horas de silencio y
/// variación aleatoria. Todo protege al número de patrones que WhatsApp castiga.
struct SendSafetyView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let instance: Instance

    // Caudal / tope
    @State private var limitHour = false
    @State private var perHour = 60
    @State private var limitDay = false
    @State private var perDay = 500
    // Horas de silencio
    @State private var quiet = false
    @State private var quietStart = Date()
    @State private var quietEnd = Date()
    // Variación aleatoria (random delay)
    @State private var jitterInMinutes = true
    @State private var jitterMin = 1
    @State private var jitterMax = 5

    @State private var busy = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Limitar envíos por hora", isOn: $limitHour)
                    if limitHour {
                        Stepper("Máximo \(perHour) por hora", value: $perHour, in: 1...600, step: 5)
                    }
                } header: {
                    Text("Caudal")
                } footer: {
                    Text("Reparte los envíos (dripping): en vez de una ráfaga, salen espaciados. Para listas grandes protege el número.")
                }

                Section {
                    Toggle("Tope diario", isOn: $limitDay)
                    if limitDay {
                        Stepper("Máximo \(perDay) al día", value: $perDay, in: 10...5000, step: 10)
                    }
                } footer: {
                    Text("Al llegar al tope, lo que falte se difiere al día siguiente (no falla).")
                }

                Section {
                    Toggle("Horas de silencio", isOn: $quiet)
                    if quiet {
                        DatePicker("Desde", selection: $quietStart, displayedComponents: [.hourAndMinute])
                        DatePicker("Hasta", selection: $quietEnd, displayedComponents: [.hourAndMinute])
                    }
                } header: {
                    Text("Horas de silencio")
                } footer: {
                    Text("En esa franja no se envía nada; lo programado se difiere al final del silencio. Útil de madrugada.")
                }

                Section {
                    Picker("Unidad", selection: $jitterInMinutes) {
                        Text("Segundos").tag(false)
                        Text("Minutos").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Mínimo: \(jitterMin) \(jitterInMinutes ? "min" : "s")", value: $jitterMin, in: 0...600)
                    Stepper("Máximo: \(jitterMax) \(jitterInMinutes ? "min" : "s")", value: $jitterMax, in: 1...600)
                } header: {
                    Text("Variación aleatoria")
                } footer: {
                    Text("Cuando un mensaje recurrente tiene activado \"variar hora\", cada envío se corre una cantidad aleatoria dentro de este rango — evita la hora exacta que delata a un bot.")
                }

                if saved {
                    Section { Label("Guardado", systemImage: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Seguridad de envío")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Guardar") }
                    }
                    .disabled(busy)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func load() {
        let h = instance.maxPerHour ?? 0
        limitHour = h > 0; if h > 0 { perHour = h }
        let d = instance.maxPerDay ?? 0
        limitDay = d > 0; if d > 0 { perDay = d }

        if let qs = instance.quietStart, let qe = instance.quietEnd, qs != qe {
            quiet = true
            quietStart = dateFrom(minutes: qs)
            quietEnd = dateFrom(minutes: qe)
        } else {
            quiet = false
            quietStart = dateFrom(minutes: 22 * 60)  // 22:00
            quietEnd = dateFrom(minutes: 7 * 60)      // 07:00
        }

        let minSec = instance.jitterMinSec ?? 60
        let maxSec = instance.jitterMaxSec ?? 300
        if minSec % 60 == 0 && maxSec % 60 == 0 && maxSec >= 60 {
            jitterInMinutes = true; jitterMin = minSec / 60; jitterMax = maxSec / 60
        } else {
            jitterInMinutes = false; jitterMin = minSec; jitterMax = maxSec
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        let unit = jitterInMinutes ? 60 : 1
        let lo = min(jitterMin, jitterMax) * unit
        let hi = max(jitterMin, jitterMax) * unit
        do {
            let updated = try await APIClient.shared.updateInstanceEnvelope(
                id: instance.id,
                maxPerHour: limitHour ? perHour : 0,
                maxPerDay: limitDay ? perDay : 0,
                quietStart: quiet ? minutesOfDay(quietStart) : 0,
                quietEnd: quiet ? minutesOfDay(quietEnd) : 0,
                jitterMinSec: lo,
                jitterMaxSec: hi
            )
            if let i = session.instances.firstIndex(where: { $0.id == instance.id }) {
                session.instances[i] = updated
            }
            saved = true
        } catch { session.report(error) }
    }

    private func minutesOfDay(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    private func dateFrom(minutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
}
