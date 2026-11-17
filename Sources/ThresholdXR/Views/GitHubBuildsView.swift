import SwiftUI
import ThresholdCore

struct GitHubBuildsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private var catalogue: BuildCatalogueController { model.buildCatalogue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GitHub Builds").font(.title2.bold())
                Spacer()
                if catalogue.checking { ProgressView().controlSize(.small) }
                Button("Check for Updates") { Task { await catalogue.refresh(installer: model.releaseInstaller) } }
                    .disabled(catalogue.checking || (catalogue.lastChecked.map { Date().timeIntervalSince($0) < 60 } ?? false))
            }
            Text("Checks at startup and hourly while Threshold XR is open. Complete experimental builds from our forks can be installed here.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(catalogue.components, id: \.self) { component in
                        row(component).padding(.vertical, 12)
                        Divider()
                    }
                }
            }
            if let error = catalogue.installError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if let message = catalogue.installMessage { Text(message).foregroundStyle(.green) }
            Text("Installation verifies checksums and keeps previous versions. Installed files do not switch your running service, launch stack or Steam setup.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let date = catalogue.lastChecked { Text("Last checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Installed Releases") { NSWorkspace.shared.open(ReleaseInstaller.defaultRoot()) }
                    .disabled(catalogue.installed.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 740, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if catalogue.lastChecked == nil { await catalogue.refresh(installer: model.releaseInstaller) }
        }
    }

    @ViewBuilder private func row(_ component: String) -> some View {
        let check = catalogue.checks[component]
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(component).font(.headline)
                    Text(ReleaseRepository.repositories[component] ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let build = check?.build {
                    let availability = build.availability(among: catalogue.installed)
                    VStack(alignment: .trailing, spacing: 3) {
                        Link(build.release.version, destination: build.page).font(.callout.monospaced())
                        Text(ByteCountFormatter.string(fromByteCount: build.release.artifacts.reduce(0) { $0 + $1.size }, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if catalogue.installing == component {
                        ProgressView("Installing…").controlSize(.small).frame(width: 130)
                    } else {
                        Button(availability.rawValue) {
                            Task { await catalogue.install(build, installer: model.releaseInstaller); await model.refreshReleaseStacks() }
                        }
                        .disabled(!availability.canInstall || catalogue.installing != nil || model.isInstallingRelease || check?.error != nil)
                    }
                } else {
                    Text(check == nil ? "Checking…" : (component == "macos-wine-xr" ? "Public packages held; use local Steam setup" : "No complete release published"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            let versions = catalogue.installed.filter { $0.release.component == component }.map { $0.release.version }.sorted()
            if !versions.isEmpty { Text("Installed: " + versions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            if let error = check?.error {
                Text("Check failed: " + error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}
