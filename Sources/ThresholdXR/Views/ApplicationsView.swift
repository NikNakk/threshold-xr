import SwiftUI
import ThresholdCore

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlaceholderNotice(
                    title: "Application library is coming in Milestone 2",
                    message: "Direct launch, per-application settings and dependency checks are not implemented yet. Below is Threshold Home's existing catalog, shown read-only so there is one application list, not two."
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = model.shellAppsError {
                            Label("The catalog could not be read: \(error)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .padding(8)
                        } else if model.shellApps.isEmpty {
                            Text("Threshold Home's catalog is empty or not present.")
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        ForEach(model.shellApps) { app in
                            HStack(spacing: 12) {
                                Image(systemName: app.systemImage ?? "app")
                                    .font(.title2)
                                    .frame(width: 32)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.title).font(.headline)
                                    if let subtitle = app.subtitle {
                                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                                    }
                                    PathText(path: model.context.expand(app.path).path,
                                             exists: FileManager.default.fileExists(atPath: model.context.expand(app.path).path))
                                }
                                Spacer()
                            }
                            .padding(8)
                            if app.id != model.shellApps.last?.id { Divider() }
                        }
                    }
                } label: {
                    HStack {
                        Text("Threshold Home catalog").font(.headline)
                        Spacer()
                        Button("Reveal File") { model.reveal(ShellAppCatalog.url(context: model.context).path) }
                            .buttonStyle(.link)
                    }
                }

                Text("Any OpenXR application can also be started from Finder, the Dock or a terminal; it finds Monado through the system OpenXR registration without Threshold XR running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}
