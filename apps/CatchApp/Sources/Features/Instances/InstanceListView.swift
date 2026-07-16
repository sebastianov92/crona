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
        .confirmationDialog("¿Eliminar esta instancia?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Eliminar \(confirmDelete?.name ?? "")", role: .destructive) {
                if let inst = confirmDelete {
                    Task {
                        _ = try? await APIClient.shared.deleteInstance(id: inst.id)
                        await session.refreshInstances()
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
    @State private var busy = false
    @State private var error: String?
    @State private var created: CreateInstanceResponse?

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    QRLinkView(instance: created.instance, initialQR: created.qrBase64)
                } else {
                    Form {
                        Section {
                            TextField("Nombre (ej. Personal, Negocio)", text: $name)
                        } footer: {
                            Text("Se creará una instancia nueva en Evolution y verás el QR para escanear con WhatsApp.")
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
        do {
            created = try await APIClient.shared.createInstance(name: name)
            await session.refreshInstances()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
