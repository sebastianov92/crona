import SwiftUI

struct InstanceListView: View {
    @Environment(SessionStore.self) private var session
    @State private var showCreate = false
    @State private var qrInstance: Instance?
    @State private var confirmDelete: Instance?
    @State private var renaming: Instance?
    @State private var renameText = ""

    var body: some View {
        List {
            if session.instances.isEmpty {
                ContentUnavailableView(
                    "Sin instancias",
                    systemImage: "qrcode",
                    description: Text("Vincula tu número de WhatsApp para empezar.")
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(session.instances) { inst in
                HStack(spacing: 12) {
                    AvatarView(name: inst.name, pictureUrl: inst.profilePicUrl)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(inst.name).font(.headline)
                            if session.user?.defaultInstanceId == inst.id {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .help("Instancia principal")
                            }
                        }
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
                    .tint(.red)
                }
                .contextMenu {
                    Button("Renombrar…") {
                        renameText = inst.name
                        renaming = inst
                    }
                    if session.user?.defaultInstanceId != inst.id {
                        Button("Usar como principal") {
                            Task { session.user = try? await APIClient.shared.patchMe(defaultInstanceId: .some(inst.id)) }
                        }
                    }
                    Divider()
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
        .alert("Renombrar instancia", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nombre", text: $renameText)
            Button("Guardar") {
                if let inst = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task {
                            if let updated = try? await APIClient.shared.renameInstance(id: inst.id, name: name),
                               let i = session.instances.firstIndex(where: { $0.id == inst.id }) {
                                session.instances[i] = updated
                            }
                        }
                    }
                }
                renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .alert(
            "¿Eliminar instancia?",
            isPresented: .init(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
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
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se desconecta el número de WhatsApp y se borran sus mensajes programados. Irreversible.")
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

