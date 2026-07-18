import SwiftUI

struct InstanceListView: View {
    @Environment(SessionStore.self) private var session
    @State private var showCreate = false
    @State private var qrInstance: Instance?
    @State private var confirmDelete: Instance?

    var body: some View {
        List {
            if session.instances.isEmpty {
                ContentUnavailableView(
                    "Sin instancias",
                    systemImage: "qrcode",
                    description: Text("Vincula tu número de WhatsApp para empezar.")
                )
            }
            ForEach(session.instances) { inst in
                HStack(spacing: 12) {
                    AvatarView(name: inst.name, pictureUrl: inst.profilePicUrl)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inst.name).font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(color(inst.status)).frame(width: 8, height: 8)
                            Text(label(inst.status)).font(.caption).foregroundStyle(.secondary)
                            if let phone = inst.phoneNumber {
                                Text("· \(phone)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if inst.status != .CONNECTED {
                        Button("Vincular número") { qrInstance = inst }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button {
                        confirmDelete = inst
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Eliminar instancia")
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { confirmDelete = inst } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button("Ver QR") { qrInstance = inst }
                    Button("Actualizar estado") {
                        Task { await refreshStatus(inst) }
                    }
                    Button("Sincronizar contactos") {
                        Task { _ = try? await APIClient.shared.syncInstance(id: inst.id) }
                    }
                    Divider()
                    Button("Eliminar", role: .destructive) { confirmDelete = inst }
                }
            }
        }
        .navigationTitle("Instancias")
        .toolbar {
            ToolbarItem {
                Button { showCreate = true } label: { Label("Vincular número", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) { CreateInstanceView() }
        .sheet(item: $qrInstance) { inst in QRLinkView(instance: inst) }
        .confirmationDialog(
            "Se desconecta el número de WhatsApp y se borran sus mensajes programados. ¿Eliminar?",
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar \(confirmDelete?.name ?? "")", role: .destructive) {
                if let inst = confirmDelete {
                    Task {
                        do {
                            _ = try await APIClient.shared.deleteInstance(id: inst.id)
                            await session.refreshInstances()
                            await session.refreshMessages()
                        } catch { session.report(error) }
                    }
                }
            }
        }
        .refreshable { await session.refreshInstances() }
        .task { await session.refreshInstances() }
    }

    private func refreshStatus(_ inst: Instance) async {
        do {
            let updated = try await APIClient.shared.instanceStatus(id: inst.id)
            if let i = session.instances.firstIndex(where: { $0.id == inst.id }) {
                session.instances[i] = updated
            }
        } catch { session.report(error) }
    }

    private func color(_ s: InstanceStatus) -> Color {
        switch s {
        case .CONNECTED: return Theme.accent
        case .CONNECTING: return .orange
        default: return .red
        }
    }
    private func label(_ s: InstanceStatus) -> String {
        switch s {
        case .CREATED: return "Sin vincular"
        case .CONNECTING: return "Conectando…"
        case .CONNECTED: return "Conectado"
        case .DISCONNECTED: return "Desconectado"
        }
    }
}

struct CreateInstanceView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var busy = false
    @State private var error: String?
    @State private var created: CreateInstanceResponse?

    private var cleanPhone: String { phone.filter(\.isNumber) }

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    QRLinkView(instance: created.instance,
                               initialQR: created.qrBase64,
                               initialPairingCode: created.pairingCode,
                               prefillNumber: cleanPhone)
                } else {
                    Form {
                        Section {
                            TextField("Nombre (ej. Personal, Negocio)", text: $name)
                        } footer: {
                            #if os(iOS)
                            Text("Como estás en el mismo teléfono, la vinculación se hace con un código que escribes en WhatsApp (no puedes escanear tu propio QR).")
                            #else
                            Text("Verás un QR para escanear con WhatsApp; también podrás usar un código si no puedes escanear.")
                            #endif
                        }
                        Section {
                            TextField("Número a vincular (ej. 593999999999)", text: $phone)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        } header: {
                            #if os(iOS)
                            Text("Número de WhatsApp")
                            #else
                            Text("Número (opcional, para vincular por código)")
                            #endif
                        } footer: {
                            Text("Con código de país y sin +. Si lo pones, se genera un código de emparejamiento.")
                        }
                        if let error { Section { Text(error).foregroundStyle(.red) } }
                    }
                    .formStyle(.grouped)
                    .navigationTitle("Vincular número")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                Task { await create() }
                            } label: {
                                if busy { ProgressView().controlSize(.small) } else { Text("Crear") }
                            }
                            .disabled(name.isEmpty || busy)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private func create() async {
        error = nil; busy = true
        defer { busy = false }
        #if os(iOS)
        guard cleanPhone.count >= 8 else {
            error = "Pon el número de WhatsApp a vincular (con código de país)."
            busy = false
            return
        }
        #endif
        do {
            created = try await APIClient.shared.createInstance(
                name: name,
                phoneNumber: cleanPhone.count >= 8 ? cleanPhone : nil
            )
            await session.refreshInstances()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
