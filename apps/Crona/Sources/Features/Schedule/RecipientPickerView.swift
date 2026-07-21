import SwiftUI

struct RecipientPickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let instanceId: String
    var multiSelect: Bool = false
    let onPick: ([Recipient]) -> Void

    @State private var kind: RecipientKind = .CONTACT
    @State private var search = ""
    @State private var items: [Recipient] = []
    @State private var selected: [Recipient] = []
    @State private var loading = false
    @State private var syncing = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @State private var showManualNumber = false
    @State private var renaming: Recipient?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tipo", selection: $kind) {
                    Text("Contactos").tag(RecipientKind.CONTACT)
                    Text("Grupos").tag(RecipientKind.GROUP)
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                // buscador propio: el de .searchable colapsa la barra y esconde Cancelar/Listo
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar por nombre o número", text: $search)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .padding()

                List {
                    if kind == .CONTACT {
                        Button {
                            showManualNumber = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "phone.badge.plus")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.accent.opacity(0.15), in: Circle())
                                Text("Enviar a un número").font(.body)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if items.isEmpty && !loading {
                        ContentUnavailableView(
                            kind == .CONTACT ? "No hay contactos. Toca \"Sincronizar contactos\"." : "No hay grupos. Toca \"Sincronizar contactos\".",
                            systemImage: "person.2"
                        )
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(items) { r in
                        Button {
                            tap(r)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: r.shownName, pictureUrl: r.pictureUrl, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.shownName).font(.body)
                                    // con alias, mostrar también el nombre original de WhatsApp
                                    if let alias = r.alias, !alias.isEmpty {
                                        Text(r.displayName).font(.caption).foregroundStyle(.secondary)
                                    } else if let phone = r.phoneNumber {
                                        Text(phone).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if multiSelect {
                                    Image(systemName: isSelected(r) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected(r) ? Theme.accent : .secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())   // toda la fila clickeable
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameText = r.alias ?? ""
                                renaming = r
                            } label: {
                                Label("Renombrar…", systemImage: "pencil")
                            }
                            if r.alias != nil {
                                Button(role: .destructive) {
                                    Task { await rename(r, alias: nil) }
                                } label: {
                                    Label("Quitar apodo", systemImage: "arrow.uturn.backward")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay { if loading { ProgressView() } }
            }
            .navigationTitle("Destinatario")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                // un solo botón que se transforma: 🔄 sin selección → "Listo (N)" con selección
                ToolbarItem(placement: .primaryAction) {
                    if multiSelect && !selected.isEmpty {
                        Button("Listo (\(selected.count))") {
                            onPick(selected)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                    } else {
                        Button {
                            Task { await sync() }
                        } label: {
                            if syncing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.triangle.2.circlepath") }
                        }
                        .help("Sincronizar contactos")
                        .disabled(syncing)
                    }
                }
            }
            .task(id: kind) { await load() }
            .task {
                // autofocus: esperar a que la hoja termine de presentarse (iOS levanta el teclado)
                try? await Task.sleep(for: .milliseconds(450))
                searchFocused = true
            }
            .onChange(of: search) {
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { await load() }
                }
            }
            .sheet(isPresented: $showManualNumber) {
                ManualNumberSheet { recipient in
                    if multiSelect {
                        if !selected.contains(where: { $0.jid == recipient.jid }) { selected.append(recipient) }
                    } else {
                        onPick([recipient])
                        dismiss()
                    }
                }
            }
            .alert("Renombrar contacto", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Apodo", text: $renameText)
                Button("Guardar") {
                    if let r = renaming {
                        let alias = renameText.trimmingCharacters(in: .whitespaces)
                        Task { await rename(r, alias: alias.isEmpty ? nil : alias) }
                    }
                    renaming = nil
                }
                Button("Cancelar", role: .cancel) { renaming = nil }
            } message: {
                Text("Este nombre solo se guarda en Crona y sirve para buscar al contacto.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func isSelected(_ r: Recipient) -> Bool {
        selected.contains { $0.jid == r.jid }
    }

    private func tap(_ r: Recipient) {
        if multiSelect {
            if let i = selected.firstIndex(where: { $0.jid == r.jid }) { selected.remove(at: i) }
            else { selected.append(r) }
        } else {
            onPick([r])
            dismiss()
        }
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

    private func rename(_ r: Recipient, alias: String?) async {
        do {
            let updated = try await APIClient.shared.renameRecipient(instanceId: instanceId, recipientId: r.id, alias: alias)
            if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = updated }
            if let i = selected.firstIndex(where: { $0.id == r.id }) { selected[i] = updated }
        } catch { session.report(error) }
    }
}

/// Hoja para programar a un número que no está en los contactos: país + número.
private struct ManualNumberSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: (Recipient) -> Void

    @State private var country = countryFor("EC")
    @State private var number = ""
    @State private var showCountries = false
    @FocusState private var numberFocused: Bool

    private var digits: String { number.filter(\.isNumber) }
    // sin el 0 inicial de formato local (0999… → 999…)
    private var normalized: String { digits.hasPrefix("0") ? String(digits.dropFirst()) : digits }
    private var full: String { country.code + normalized }
    private var valid: Bool { normalized.count >= 7 && full.count <= 15 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showCountries = true
                    } label: {
                        HStack {
                            Text("\(country.flag) \(country.name)")
                            Spacer()
                            Text("+\(country.code)").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField("Número (ej. 991234567)", text: $number)
                        .focused($numberFocused)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                } footer: {
                    if valid {
                        Text("Se enviará a +\(full)")
                    } else {
                        Text("Escribe el número sin el código de país.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Enviar a un número")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        let r = Recipient(
                            id: "manual-\(full)",
                            jid: "\(full)@s.whatsapp.net",
                            displayName: "+\(full)",
                            alias: nil,
                            pictureUrl: nil,
                            kind: .CONTACT,
                            phoneNumber: full
                        )
                        onDone(r)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                numberFocused = true
            }
            .sheet(isPresented: $showCountries) {
                CountryPickerSheet(selection: $country)
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 320)
        #endif
    }
}
