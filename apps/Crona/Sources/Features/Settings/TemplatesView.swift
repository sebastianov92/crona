import SwiftUI

/// CRUD de plantillas. Se ven las propias y las públicas de cualquiera,
/// pero editar es solo del creador (el servidor responde 403 si no).
struct TemplatesView: View {
    @Environment(SessionStore.self) private var session

    var kind: TemplateKind = .MESSAGE

    @State private var templates: [MessageTemplate] = []
    @State private var editing: MessageTemplate?
    @State private var showCreate = false
    @State private var deleting: MessageTemplate?

    private var mine: [MessageTemplate] { templates.filter { $0.ownerId == session.user?.id } }
    private var others: [MessageTemplate] { templates.filter { $0.ownerId != session.user?.id } }

    var body: some View {
        Form {
            Section {
                if mine.isEmpty {
                    Text("Aún no tienes plantillas. Crea una con el botón +.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mine) { tpl in row(tpl, isMine: true) }
            } header: {
                Text("Mis plantillas")
            } footer: {
                Text(kind == .GROUP_INITIAL
                     ? "Se usan como mensaje inicial al crear un grupo."
                     : "Al usarlas se copian al mensaje: editar el texto no cambia la plantilla.")
            }

            if !others.isEmpty {
                Section {
                    ForEach(others) { tpl in row(tpl, isMine: false) }
                } header: {
                    Text("Públicas")
                } footer: {
                    Text("Compartidas por otros usuarios. Puedes usarlas, pero solo su creador puede editarlas.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind == .GROUP_INITIAL ? "Plantillas de grupo" : "Plantillas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label("Nueva plantilla", systemImage: "plus") }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate, onDismiss: { Task { await load() } }) {
            TemplateEditView(template: nil, kind: kind)
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { tpl in
            TemplateEditView(template: tpl, kind: tpl.kind)
        }
        .alert("¿Eliminar plantilla?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("Eliminar", role: .destructive) {
                if let tpl = deleting { Task { await remove(tpl) } }
                deleting = nil
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: {
            Text("\"\(deleting?.name ?? "")\" dejará de estar disponible.")
        }
    }

    @ViewBuilder
    private func row(_ tpl: MessageTemplate, isMine: Bool) -> some View {
        TemplateRow(template: tpl, isMine: isMine)
            .contentShape(Rectangle())
            .onTapGesture { if isMine { editing = tpl } }
            .swipeActions(edge: .trailing) {
                if isMine || session.isAdmin {
                    Button(role: .destructive) { deleting = tpl } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .contextMenu {
                if isMine { Button("Editar") { editing = tpl } }
                if isMine || session.isAdmin {
                    Button("Eliminar", role: .destructive) { deleting = tpl }
                }
            }
    }

    private func load() async {
        templates = (try? await APIClient.shared.templates(kind: kind).items) ?? []
    }

    private func remove(_ tpl: MessageTemplate) async {
        do {
            _ = try await APIClient.shared.deleteTemplate(id: tpl.id)
            await load()
        } catch { session.report(error) }
    }
}

struct TemplateEditView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let template: MessageTemplate?
    let kind: TemplateKind

    @State private var name = ""
    @State private var isPublic = false
    @State private var parts: [PartDraft] = [PartDraft()]
    @State private var busy = false
    @State private var error: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        parts.contains { !$0.isEmpty } && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Ej. Saludo de bienvenida", text: $name)
                }
                Section {
                    PartsEditor(parts: $parts, minParts: 1, maxParts: 10)
                } header: {
                    Text(parts.count > 1 ? "Mensajes (\(parts.count))" : "Mensaje")
                } footer: {
                    Text("Cada parte se envía como un mensaje aparte, con una pausa corta entre ellos.")
                }
                Section {
                    Toggle("Pública", isOn: $isPublic)
                } footer: {
                    Text("Las plantillas públicas las ven y usan todos los usuarios, pero solo tú puedes editarlas.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(template == nil ? "Nueva plantilla" : "Editar plantilla")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("Guardar") }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                guard let template else { return }
                name = template.name
                isPublic = template.isPublic
                parts = template.parts.map { PartDraft(text: $0.body, presetTypingMs: $0.typingMs) }
                if parts.isEmpty { parts = [PartDraft()] }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
        #endif
    }

    private func save() async {
        busy = true; defer { busy = false }
        let payload = parts.filter { !$0.isEmpty }.map(\.templatePart)
        do {
            if let template {
                _ = try await APIClient.shared.patchTemplate(
                    id: template.id, name: name.trimmingCharacters(in: .whitespaces),
                    isPublic: isPublic, parts: payload)
            } else {
                _ = try await APIClient.shared.createTemplate(
                    name: name.trimmingCharacters(in: .whitespaces), kind: kind,
                    isPublic: isPublic, parts: payload)
            }
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
