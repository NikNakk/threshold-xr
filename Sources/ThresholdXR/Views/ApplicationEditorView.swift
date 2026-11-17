import AppKit
import SwiftUI
import ThresholdCore

struct ApplicationEditorDraft: Identifiable {
    let id = UUID()
    let source: ApplicationCatalog.Source
    let url: URL
    let original: Data?
    let originalID: String?
    let json: Data

    static func manual(context: DiscoveryContext, id: String? = nil) throws -> Self {
        let url = ShellAppCatalog.url(context: context)
        let original = try? Data(contentsOf: url)
        let entries = try ShellAppCatalog.load(context: context)
        let json: Data
        if let id, let entry = entries.first(where: { $0.id == id }) {
            json = try JSONEncoder().encode(entry)
        } else if id != nil {
            throw ApplicationEditingError.invalid("This application is no longer in the catalog. Reload the list.")
        } else {
            json = Data("{\"id\":\"\(UUID().uuidString.lowercased())\",\"title\":\"\",\"path\":\"\",\"arguments\":[],\"environment\":{}}".utf8)
        }
        return Self(source: .shellCatalog, url: url, original: original, originalID: id, json: json)
    }
}

struct ApplicationEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: ApplicationEditorDraft
    @State private var title: String
    @State private var subtitle: String
    @State private var icon: String
    @State private var clientName: String
    @State private var path: String
    @State private var identifier: String
    @State private var arguments: String
    @State private var environment: String
    @State private var components: String
    @State private var additional: String
    @State private var error: String?

    init(draft: ApplicationEditorDraft) {
        self.draft = draft
        var object = (try? JSONSerialization.jsonObject(with: draft.json)) as? [String: Any] ?? [:]
        let runtime = draft.source == .framework
        _title = State(initialValue: object.removeValue(forKey: "title") as? String ?? "")
        _subtitle = State(initialValue: object.removeValue(forKey: "subtitle") as? String ?? "")
        _icon = State(initialValue: object.removeValue(forKey: runtime ? "system_image" : "systemImage") as? String ?? "")
        _clientName = State(initialValue: object.removeValue(forKey: runtime ? "openxr_application_name" : "openXRApplicationName") as? String ?? "")
        _identifier = State(initialValue: object.removeValue(forKey: "id") as? String ?? "")
        _path = State(initialValue: runtime ? "" : object.removeValue(forKey: "path") as? String ?? "")
        if runtime, let guest = object["guest"] as? String, var section = object[guest] as? [String: Any] {
            _arguments = State(initialValue: Self.pretty(section.removeValue(forKey: "arguments") ?? []))
            object[guest] = section
        } else {
            _arguments = State(initialValue: Self.pretty(object.removeValue(forKey: "arguments") ?? []))
        }
        _environment = State(initialValue: Self.pretty(object.removeValue(forKey: "environment") ?? [:]))
        _components = State(initialValue: Self.pretty(object.removeValue(forKey: "components") ?? [:]))
        _additional = State(initialValue: Self.pretty(object))
    }

    private var runtime: Bool { draft.source == .framework }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(runtime ? "Edit Runtime Application" : draft.originalID == nil ? "Add Application" : "Edit Application")
                .font(.title2.bold())
            ScrollView {
                Form {
                    TextField("Name", text: $title)
                    TextField("Description", text: $subtitle)
                    TextField("ID", text: $identifier).disabled(runtime)
                    TextField("Symbol name", text: $icon)
                    TextField("OpenXR application name", text: $clientName)
                    if !runtime {
                        HStack {
                            TextField("Application or executable path", text: $path)
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url { path = url.path }
                            }
                        }
                    } else {
                        Text("Host, loader and graphics dependencies (JSON object of paths)")
                        jsonEditor($components, height: 100)
                    }
                    Text("Arguments (JSON array; each string is one argument)")
                    jsonEditor($arguments, height: 65)
                    Text("Environment (JSON object of string values)")
                    jsonEditor($environment, height: 100)
                    if runtime {
                        DisclosureGroup("Advanced profile settings") {
                            Text("Guest settings, parameters, Monado requirements and other profile fields. Existing settings are preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                            jsonEditor($additional, height: 250)
                        }
                    }
                }.formStyle(.grouped)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .lineLimit(5)
            }
            HStack {
                Button("Reveal File") { model.reveal(draft.url.path) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!runtime && path.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 720, height: 680)
    }

    private func jsonEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(.caption, design: .monospaced))
            .frame(height: height).border(.secondary.opacity(0.3))
    }

    private static func pretty(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func save() {
        do {
            guard let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String],
                  let env = try JSONSerialization.jsonObject(with: Data(environment.utf8)) as? [String: String] else {
                throw ApplicationEditingError.invalid("Arguments must be an array of strings; environment must be an object of string values.")
            }
            var object: [String: Any] = [:]
            if runtime {
                guard let extra = try JSONSerialization.jsonObject(with: Data(additional.utf8)) as? [String: Any],
                      let deps = try JSONSerialization.jsonObject(with: Data(components.utf8)) as? [String: String] else {
                    throw ApplicationEditingError.invalid("Profile settings and components must be JSON objects.")
                }
                object = extra
                object["components"] = deps
            }
            object["id"] = identifier
            object["title"] = title
            object["subtitle"] = subtitle.isEmpty ? nil : subtitle
            object[runtime ? "system_image" : "systemImage"] = icon.isEmpty ? nil : icon
            object[runtime ? "openxr_application_name" : "openXRApplicationName"] = clientName.isEmpty ? nil : clientName
            if !runtime { object["path"] = path }
            if runtime, let guest = object["guest"] as? String, var section = object[guest] as? [String: Any] {
                section["arguments"] = args
                object[guest] = section
            } else if !runtime { object["arguments"] = args }
            object["environment"] = env
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if runtime {
                try ApplicationEditing.saveProfile(data, to: draft.url, original: draft.json)
            } else {
                try ApplicationEditing.saveManual(data, originalID: draft.originalID, original: draft.original, context: model.context)
            }
            Task { await model.discoverComponents() }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
