import SwiftUI
import ThresholdCore

/// A staged edit to a Monado setting.
enum DraftChange: Equatable {
    case set(SettingValue)
    case reset
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var drafts: [String: DraftChange] = [:]
    @State private var showAdvanced = false
    @State private var confirmReload = false
    @State private var saving = false

    var body: some View {
        Form {
            monadoSection
            appSection
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Toggle("Show Advanced", isOn: $showAdvanced)
                    .toggleStyle(.switch)
                    .help("Show advanced and developer settings")
            }
        }
        .onAppear { showAdvanced = model.preferences.showAdvancedSettings }
        .onChange(of: showAdvanced) { _, value in model.preferences.showAdvancedSettings = value }
        .confirmationDialog("Reload Monado's LaunchAgent?", isPresented: $confirmReload) {
            Button("Reload Service", role: .destructive) { model.perform(.reload) }
        } message: {
            Text(reloadMessage)
        }
    }

    // MARK: Monado

    @ViewBuilder
    private var monadoSection: some View {
        let values = model.monadoSettings.filter { showAdvanced || !$0.descriptor.isAdvanced }
        let groups = Dictionary(grouping: values, by: \.descriptor.group)
        let order = SettingsCatalog.monado.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        Section {
            if let error = model.monadoSettingsError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These values are stored in Monado's own LaunchAgent, where Monado's installer and preference scripts keep them. Threshold XR edits only the variables you change and backs up the file first.")
                        .foregroundStyle(.secondary)
                    if let agent = model.monado?.installation.agentPlistURL {
                        PathText(path: agent.path)
                    }
                }
                pendingBanner
            }
        } header: {
            Text("Monado").font(.title3.weight(.semibold))
        }

        ForEach(order.filter { groups[$0] != nil }, id: \.self) { group in
            Section(group) {
                ForEach(groups[group] ?? [], id: \.descriptor.id) { value in
                    MonadoSettingRow(value: value, draft: binding(for: value.descriptor.id))
                }
            }
        }

        if !model.monadoSettings.isEmpty {
            Section {
                HStack {
                    if let backup = model.lastBackup {
                        Button("Show Backup") { model.reveal(backup.path) }
                            .buttonStyle(.link)
                    }
                    Spacer()
                    Button("Revert") { drafts.removeAll() }
                        .disabled(drafts.isEmpty || saving)
                    Button("Save Changes") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(drafts.isEmpty || saving || validationProblem != nil)
                }
                if let problem = validationProblem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingBanner: some View {
        if let status = model.monado, !status.pendingEnvironmentChanges.isEmpty {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved changes are not active yet").font(.headline)
                    Text("launchd reads the LaunchAgent only when it is loaded. Reload it to apply: \(status.pendingEnvironmentChanges.joined(separator: ", ")).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reload Service…") { confirmReload = true }
                    .disabled(model.busyAction != nil)
            }
            .padding(.vertical, 4)
        }
    }

    private var reloadMessage: String {
        guard let status = model.monado else { return "" }
        if status.isServiceRunning {
            let clients = status.connectedClientEstimate ?? 0
            return "Monado is running\(clients > 0 ? " with \(clients) connection(s)" : ""). Reloading stops it; applications will start it again with the new settings when they connect."
        }
        return "Monado is idle. Reloading re-registers it with the new settings; it will start on demand as before."
    }

    private func binding(for id: String) -> Binding<DraftChange?> {
        Binding(get: { drafts[id] }, set: { drafts[id] = $0 })
    }

    private var validationProblem: String? {
        for (id, change) in drafts {
            guard case let .set(value) = change, let descriptor = SettingsCatalog.descriptor(id: id) else { continue }
            if let problem = descriptor.validate(value) { return problem }
        }
        return nil
    }

    private func save() {
        saving = true
        let changes = drafts.mapValues { change -> SettingValue? in
            if case let .set(value) = change { return value }
            return nil
        }
        Task {
            if await model.saveMonadoSettings(changes) { drafts.removeAll() }
            saving = false
        }
    }

    // MARK: Threshold XR

    @ViewBuilder
    private var appSection: some View {
        Section {
            ForEach(SettingsCatalog.app) { descriptor in
                AppSettingRow(descriptor: descriptor)
            }
        } header: {
            Text("Threshold XR").font(.title3.weight(.semibold))
        } footer: {
            Text("Stored in Threshold XR's preferences. Changes apply immediately.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Rows

private struct MonadoSettingRow: View {
    @Environment(AppModel.self) private var model
    let value: MonadoSettingValue
    @Binding var draft: DraftChange?

    private var descriptor: SettingDescriptor { value.descriptor }

    /// The value shown in the control: draft, else saved, else default.
    private var shown: SettingValue? {
        switch draft {
        case let .set(v): return v
        case .reset: return descriptor.defaultValue
        case nil: return value.effectiveValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(descriptor.title)
                        if draft != nil { StatusPill(text: "Edited", tone: .neutral) }
                        if descriptor.isDeveloper { StatusPill(text: "Developer", tone: .inactive) }
                    }
                    Text(descriptor.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                SettingControl(descriptor: descriptor, value: shown) { draft = .set($0) }
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text(descriptor.environmentVariable ?? "").font(.caption.monospaced())
                Text(stateText).font(.caption)
                Text(descriptor.applyMode.rawValue).font(.caption)
                Spacer()
                if value.isSet || draft == .set(descriptor.defaultValue ?? .text("")) {
                    Button("Use Monado Default") { draft = .reset }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(draft == .reset)
                        .help("Remove the variable so Monado uses its built-in default.")
                }
            }
            .foregroundStyle(.secondary)
            if value.recognisedByInstalledService == false {
                Label("The installed monado-service does not read this variable.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if value.isPendingReload && draft == nil {
                Label("Saved value differs from the running configuration (\(value.loadedRaw ?? "unset")).", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        if draft == .reset { return "Will use default" }
        if let raw = value.raw {
            return value.value == nil ? "Saved: \(raw) (unrecognised)" : "Saved"
        }
        let defaultText = descriptor.defaultValue.map { " (\($0.displayString))" } ?? ""
        return "Not set · Monado default\(defaultText)"
    }
}

private struct AppSettingRow: View {
    @Environment(AppModel.self) private var model
    let descriptor: SettingDescriptor
    @State private var current: SettingValue?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                Text(descriptor.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            SettingControl(descriptor: descriptor, value: current) { newValue in
                do {
                    try model.preferences.set(newValue, for: descriptor)
                    current = newValue
                    model.preferencesChanged()
                } catch {
                    model.error = UserFacingError("Could not change \(descriptor.title)", error)
                }
            }
            .frame(maxWidth: 320, alignment: .trailing)
        }
        .onAppear { current = model.preferences.effectiveValue(for: descriptor) }
    }
}

/// A native control for a setting type. Text and number fields commit on
/// Return or when focus leaves the field.
private struct SettingControl: View {
    let descriptor: SettingDescriptor
    let value: SettingValue?
    let onChange: (SettingValue) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        switch descriptor.type {
        case .toggle:
            Toggle("", isOn: Binding(get: { value?.bool ?? false }, set: { onChange(.bool($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
        case let .choice(choices):
            Picker("", selection: Binding(get: { value ?? choices.first?.value ?? .integer(0) }, set: { onChange($0) })) {
                ForEach(choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
            }
            .labelsHidden()
            .fixedSize()
        case let .integer(_, unit), let .decimal(_, _, unit):
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($focused)
                    .onSubmit(commitNumber)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commitNumber() } }
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
            .onAppear { text = value?.displayString ?? "" }
            .onChange(of: value) { _, newValue in if !focused { text = newValue?.displayString ?? "" } }
        case .filePath, .directoryPath, .text:
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .focused($focused)
                    .onSubmit { commitText() }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commitText() } }
                if descriptor.type != .text {
                    Button("Choose…", action: choose)
                }
            }
            .onAppear { text = value?.text ?? "" }
            .onChange(of: value) { _, newValue in if !focused { text = newValue?.text ?? "" } }
        }
    }

    private func commitNumber() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed: SettingValue?
        if case .integer = descriptor.type { parsed = Int(trimmed).map(SettingValue.integer) }
        else { parsed = Double(trimmed).map(SettingValue.decimal) }
        if let parsed, parsed != value { onChange(parsed) }
        else if parsed == nil { text = value?.displayString ?? "" }
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != value?.text { onChange(.text(trimmed)) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = descriptor.type == .directoryPath
        panel.canChooseFiles = descriptor.type != .directoryPath
        if case let .filePath(extensions) = descriptor.type, !extensions.isEmpty {
            panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        }
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
            onChange(.text(url.path))
        }
    }
}
