import SwiftUI

struct RecipientPickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let instanceId: String
    let onPick: (Recipient) -> Void

    @State private var kind: RecipientKind = .CONTACT
    @State private var search = ""
    @State private var items: [Recipient] = []
    @State private var loading = false
    @State private var syncing = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tipo", selection: $kind) {
                    Text("Contactos").tag(RecipientKind.CONTACT)
                    Text("Grupos").tag(RecipientKind.GROUP)
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    if items.isEmpty && !loading {
                        ContentUnavailableView(
                            kind == .CONTACT ? "No hay contactos. Toca \"Sincronizar contactos\"." : "No hay grupos. Toca \"Sincronizar contactos\".",
                            systemImage: "person.2"
                        )
                        .listRowSeparator(.hidden)
                    }
                    ForEach(items) { r in
                        Button {
                            onPick(r)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: r.displayName, pictureUrl: r.pictureUrl, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.displayName).font(.body)
                                    if let phone = r.phoneNumber {
                                        Text(phone).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
                .overlay { if loading { ProgressView() } }
            }
            .navigationTitle("Destinatario")
            .searchable(text: $search, prompt: "Buscar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sync() }
                    } label: {
                        if syncing { ProgressView().controlSize(.small) }
                        else { Label("Sincronizar contactos", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(syncing)
                }
            }
            .task(id: kind) { await load() }
            .onChange(of: search) {
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { await load() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await APIClient.shared.recipients(instanceId: instanceId, kind: kind, search: search).items
        } catch { session.report(error) }
    }

    private func sync() async {
        syncing = true
        defer { syncing = false }
        do {
            _ = try await APIClient.shared.syncInstance(id: instanceId)
            await load()
        } catch { session.report(error) }
    }
}
