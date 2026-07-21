import SwiftUI

// Flujo de vinculación estilo asistente: número → consentimiento → código de emparejamiento.
// (países y prefijos en CountryPicker.swift)

struct CreateInstanceView: View {
    enum Step { case number, consent, code, connected }

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .number
    @State private var country = countryFor("EC")
    @State private var number = ""
    @State private var accepted = false
    @State private var showCountryPicker = false
    @State private var busy = false
    @State private var error: String?
    @State private var created: CreateInstanceResponse?
    @State private var pairingCode: String?
    @State private var qrBase64: String?
    // Mac: escanear QR con el teléfono es lo natural; iOS: WhatsApp está en el mismo equipo → código
    #if os(macOS)
    @State private var showQR = true
    #else
    @State private var showQR = false
    #endif
    @State private var copied = false
    @State private var pollTask: Task<Void, Never>?

    private var fullNumber: String { country.code + number.filter(\.isNumber) }
    private var numberValid: Bool { number.filter(\.isNumber).count >= 6 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        iconsHeader
                        switch step {
                        case .number: numberStep
                        case .consent: consentStep
                        case .code: codeStep
                        case .connected: connectedStep
                        }
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                }
                bottomBar
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .consent || step == .code {
                        Button { goBack() } label: { Image(systemName: "arrow.left") }
                    } else if step != .connected {
                        Button("Cancelar") { dismiss() }
                    }
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(selection: $country)
        }
        #if os(macOS)
        // alto suficiente para el paso del QR (header 80 + número + QR 230 + instrucciones + botones) sin scroll
        .frame(minWidth: 520, minHeight: 780)
        #endif
    }

    // MARK: - Pasos

    private var iconsHeader: some View {
        HStack(spacing: 18) {
            Spacer()
            Image("WizardWhatsApp")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            Image(systemName: "arrow.left.arrow.right")
                .font(.title3)
                .foregroundStyle(.secondary)
            Image("WizardCrona")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            Spacer()
        }
        .padding(.top, 12)
    }

    private var numberStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ingresa tu número")
                .font(.largeTitle.bold())
            Text("El mismo número de teléfono que usas en WhatsApp.")
                .foregroundStyle(.secondary)

            Text("Tu número de teléfono")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button {
                    showCountryPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(country.flag)
                        Text("+\(country.code)")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()

                TextField("Tu número aquí", text: $number)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
    }

    private var consentStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Estás a 2 pasos de activar Crona")
                .font(.largeTitle.bold())
            Text("Programar mensajes, respuestas automáticas y más — todo desde tu propio WhatsApp.")
                .foregroundStyle(.secondary)

            Button {
                accepted.toggle()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(accepted ? Theme.accent : .secondary)
                    Text("Entiendo que al conectar WhatsApp, Crona podrá procesar y enviar mensajes por mí.")
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(showQR ? "Escanea este código" : "Escribe este código en WhatsApp")
                .font(.largeTitle.bold())
            Text("Verifica que tu número sea correcto.")
                .foregroundStyle(.secondary)

            HStack {
                Text("+\(fullNumber)")
                Spacer()
                Button("Editar") { goBack(to: .number) }
                    .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            Divider()

            if showQR {
                qrContent
            } else {
                codeContent
            }
        }
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Text(formatCode(pairingCode ?? "········"))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .kerning(1)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 18).padding(.horizontal, 16)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Abre WhatsApp y toca \"Tú\" o \"Configuración\"")
                Text("2. Toca \"Dispositivos vinculados\"")
                Text("3. Toca \"Vincular dispositivo\"")
                Text("4. Elige \"Vincular con el número de teléfono\"")
                Text("5. Escribe o pega el código de 8 dígitos")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("¿Prefieres escanear un QR?") {
                showQR = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
    }

    private var qrContent: some View {
        VStack(spacing: 14) {
            if let qrBase64, let image = decodeQR(qrBase64) {
                image.resizable().interpolation(.none).scaledToFit()
                    .frame(width: 230, height: 230)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView().frame(height: 230).frame(maxWidth: .infinity)
            }
            Text("WhatsApp → Dispositivos vinculados → Vincular dispositivo → escanea.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("¿Prefieres escribir un código?") { showQR = false }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
    }

    private var connectedStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundStyle(Theme.accent)
            Text("¡WhatsApp vinculado!").font(.title.bold())
            Text("Ya puedes programar mensajes desde Crona.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    // MARK: - Barra inferior

    private var bottomBar: some View {
        VStack(spacing: 10) {
            switch step {
            case .number:
                bigButton("Continuar", disabled: !numberValid) { step = .consent }
            case .consent:
                bigButton("Continuar", disabled: !accepted || busy) { Task { await createInstance() } }
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            case .code:
                bigButton("Ya ingresé el código", disabled: false) { /* el polling detecta la conexión */ }
                Button("Generar código nuevo") { Task { await regenerateCode() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(busy)
            case .connected:
                bigButton("Listo", disabled: false) { dismiss() }
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
    }

    private func bigButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy && step == .consent { ProgressView().controlSize(.small) }
                else { Text(title).font(.headline) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(disabled ? Color.gray.opacity(0.3) : Theme.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Lógica

    private func goBack(to target: Step? = nil) {
        error = nil
        switch target ?? step {
        case .consent: step = .number
        case .code: step = .consent
        default: step = .number
        }
        if target == .number { step = .number }
    }

    private func autoName() -> String {
        let existing = Set(session.instances.map(\.name))
        if !existing.contains("Personal") { return "Personal" }
        var i = 2
        while existing.contains("Personal \(i)") { i += 1 }
        return "Personal \(i)"
    }

    private func createInstance() async {
        error = nil; busy = true
        defer { busy = false }
        do {
            let r = try await APIClient.shared.createInstance(name: autoName(), phoneNumber: fullNumber)
            created = r
            pairingCode = r.pairingCode
            qrBase64 = r.qrBase64
            await session.refreshInstances()
            if pairingCode == nil {
                // algunos 2.x no devuelven código en create: pedirlo explícito
                if let q = try? await APIClient.shared.instanceQR(id: r.instance.id, number: fullNumber) {
                    pairingCode = q.pairingCode ?? pairingCode
                    qrBase64 = q.qrBase64 ?? qrBase64
                }
            }
            step = .code
            startPolling(instanceId: r.instance.id)
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func regenerateCode() async {
        guard let created else { return }
        busy = true; defer { busy = false }
        if let q = try? await APIClient.shared.instanceQR(id: created.instance.id, number: fullNumber) {
            if let code = q.pairingCode { pairingCode = code }
            if let qr = q.qrBase64 { qrBase64 = qr }
        }
    }

    private func startPolling(instanceId: String) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if let updated = try? await APIClient.shared.instanceStatus(id: instanceId) {
                    if let i = session.instances.firstIndex(where: { $0.id == instanceId }) {
                        session.instances[i] = updated
                    }
                    if updated.status == .CONNECTED {
                        step = .connected
                        return
                    }
                }
            }
        }
    }

    private func copyCode() {
        guard let pairingCode else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
        #else
        UIPasteboard.general.string = pairingCode
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func formatCode(_ c: String) -> String {
        guard c.count == 8, !c.contains("-") else { return c }
        return "\(c.prefix(4)) - \(c.suffix(4))"
    }

    private func decodeQR(_ base64: String) -> Image? {
        let raw = base64.contains(",") ? String(base64.split(separator: ",").last ?? "") : base64
        guard let data = Data(base64Encoded: raw) else { return nil }
        #if os(macOS)
        guard let img = NSImage(data: data) else { return nil }
        return Image(nsImage: img)
        #else
        guard let img = UIImage(data: data) else { return nil }
        return Image(uiImage: img)
        #endif
    }
}
