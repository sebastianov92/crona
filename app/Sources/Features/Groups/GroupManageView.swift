import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Gestión de un grupo ya creado (F6): enlace de invitación (primero), asunto/descripción y
/// participantes. Además permite programar un mensaje directo al grupo.
struct GroupManageView: View {
    @Environment(SessionStore.self) private var session
    let group: GroupCreation

    @State private var invite: GroupInvite?
    @State private var info: GroupInfo?
    @State private var loadingInvite = true
    @State private var loadingParts = true
    @State private var subject: String
    @State private var descr: String = ""
    @State private var descrLoaded = false
    @State private var showAddPicker = false
    @State private var showCompose = false
    @State private var confirmRevoke = false
    @State private var busy = false
    @State private var copied = false

    init(group: GroupCreation) {
        self.group = group
        _subject = State(initialValue: group.name)
    }

    private var groupRecipient: Recipient {
        Recipient(id: group.groupJid ?? group.id, jid: group.groupJid ?? "", displayName: subject,
                  alias: nil, pictureUrl: nil, kind: .GROUP, phoneNumber: nil)
    }

    var body: some View {
        Form {
            inviteSection
            settingsSection
            participantsSection
            Section {
                Button {
                    showCompose = true
                } label: {
                    Label("Programar mensaje a este grupo", systemImage: "paperplane")
                }
                .disabled(group.groupJid == nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(subject)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .sheet(isPresented: $showAddPicker) {
            RecipientPickerView(instanceId: group.instanceId, startInMulti: true, allowGroups: false) { picked in
                Task { await addParticipants(picked) }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(initialRecipients: [groupRecipient], initialInstanceId: group.instanceId)
        }
        .alert("¿Regenerar el enlace?", isPresented: $confirmRevoke) {
            Button("Regenerar", role: .destructive) { Task { await revoke() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El enlace actual dejará de funcionar y se creará uno nuevo.")
        }
    }

    // MARK: - Enlace de invitación

    private var inviteSection: some View {
        Section {
            if let invite {
                Text(invite.link)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button {
                        copy(invite.link)
                    } label: { Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    ShareLink(item: invite.link) { Label("Compartir", systemImage: "square.and.arrow.up") }
                }
                Button(role: .destructive) { confirmRevoke = true } label: {
                    Label("Regenerar enlace", systemImage: "arrow.triangle.2.circlepath")
                }
            } else if loadingInvite {
                HStack { ProgressView(); Text("Obteniendo enlace…").foregroundStyle(.secondary) }
            } else {
                Button { Task { await loadInvite() } } label: { Label("Obtener enlace de invitación", systemImage: "link") }
            }
        } header: {
            Text("Enlace de invitación")
        } footer: {
            Text("Comparte este enlace para que se unan al grupo sin agregarlos uno por uno.")
        }
    }

    // MARK: - Asunto y descripción

    private var settingsSection: some View {
        Section("Datos del grupo") {
            LabeledContent("Nombre") {
                TextField("Nombre", text: $subject).multilineTextAlignment(.trailing)
            }
            if subject.trimmingCharacters(in: .whitespaces) != group.name, !subject.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { Task { await saveSubject() } } label: { Label("Guardar nombre", systemImage: "checkmark.circle") }
                    .disabled(busy)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Descripción").font(.caption).foregroundStyle(.secondary)
                TextField("Descripción (opcional)", text: $descr, axis: .vertical).lineLimit(1...5)
            }
            if descrLoaded, descr != (info?.description ?? "") {
                Button { Task { await saveDescription() } } label: { Label("Guardar descripción", systemImage: "checkmark.circle") }
                    .disabled(busy)
            }
        }
    }

    // MARK: - Participantes

    private var participantsSection: some View {
        Section {
            if loadingParts {
                HStack { ProgressView(); Text("Cargando…").foregroundStyle(.secondary) }
            } else if let info {
                ForEach(info.participants) { m in
                    HStack {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(m.phone)
                        if m.isAdmin {
                            Text("admin").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.2), in: Capsule()).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await remove(m) } } label: { Label("Quitar", systemImage: "person.badge.minus") }
                    }
                }
            }
        } header: {
            HStack {
                Text("Participantes\(info.map { " (\($0.size))" } ?? "")")
                Spacer()
                Button { showAddPicker = true } label: { Label("Agregar", systemImage: "person.badge.plus") }
                    .font(.caption).textCase(nil)
            }
        }
    }

    // MARK: - Acciones

    private func load() async {
        await loadInvite()
        await loadParticipants()
    }

    private func loadInvite() async {
        loadingInvite = true
        invite = try? await APIClient.shared.groupInvite(id: group.id)
        loadingInvite = false
    }

    private func loadParticipants() async {
        loadingParts = true
        do {
            let i = try await APIClient.shared.groupParticipants(id: group.id)
            info = i
            descr = i.description ?? ""
            descrLoaded = true
        } catch { session.report(error) }
        loadingParts = false
    }

    private func saveSubject() async {
        busy = true; defer { busy = false }
        do { _ = try await APIClient.shared.patchGroup(id: group.id, subject: subject.trimmingCharacters(in: .whitespaces)) }
        catch { session.report(error) }
    }

    private func saveDescription() async {
        busy = true; defer { busy = false }
        do {
            _ = try await APIClient.shared.patchGroup(id: group.id, description: descr)
            await loadParticipants()   // refresca la descripción base
        } catch { session.report(error) }
    }

    private func addParticipants(_ picked: [Recipient]) async {
        let jids = picked.map(\.jid).filter { !$0.isEmpty }
        guard !jids.isEmpty else { return }
        do {
            _ = try await APIClient.shared.updateGroupParticipants(id: group.id, action: "add", jids: jids)
            await loadParticipants()
        } catch { session.report(error) }
    }

    private func remove(_ m: GroupMember) async {
        do {
            _ = try await APIClient.shared.updateGroupParticipants(id: group.id, action: "remove", jids: [m.jid])
            await loadParticipants()
        } catch { session.report(error) }
    }

    private func revoke() async {
        do { invite = try await APIClient.shared.revokeGroupInvite(id: group.id) }
        catch { session.report(error) }
    }

    private func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #endif
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
