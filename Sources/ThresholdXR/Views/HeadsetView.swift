import SwiftUI
import ThresholdCore

struct HeadsetView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmQuery = false

    var body: some View {
        Form {
            if let status = model.monado {
                Section("PS VR2") {
                    LabeledContent("Headset") {
                        let summary = status.headsetSummary
                        StatusPill(text: summary.0, tone: summary.2)
                    }
                    LabeledContent("USB") {
                        if let headset = status.headsetUSB.headset {
                            Text(String(format: "Sony %04X:%04X%@", headset.vendorID, headset.productID,
                                        headset.productName.map { " · \($0)" } ?? ""))
                        } else {
                            Text("Not present").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(status.headsetUSB.otherSonyDevices, id: \.self) { device in
                        LabeledContent("Other Sony device") {
                            Text(String(format: "%04X:%04X%@", device.vendorID, device.productID,
                                        device.productName.map { " · \($0)" } ?? ""))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("USB presence is read passively from the IOKit registry; the headset is never opened, so this is safe while Monado is using it.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section {
                    switch status.runtimeQuery {
                    case let .succeeded(snapshot):
                        LabeledContent("libmonado API", value: snapshot.apiVersion)
                        LabeledContent("Read at", value: snapshot.takenAt.formatted(date: .omitted, time: .standard))
                        ForEach(snapshot.devices) { device in
                            LabeledContent(device.isHead ? "Head device" : "Device \(device.index)") {
                                Text([device.name, device.serial].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        ForEach(snapshot.clients) { client in
                            LabeledContent("Client \(client.id)") {
                                HStack {
                                    Text(client.name.isEmpty ? "Unnamed" : client.name)
                                    if client.flags.contains(.primaryApplication) { StatusPill(text: "Primary", tone: .good) }
                                    if client.flags.contains(.sessionFocused) { StatusPill(text: "Focused", tone: .neutral) }
                                    if client.flags.contains(.sessionOverlay) { StatusPill(text: "Overlay", tone: .inactive) }
                                }
                            }
                        }
                    case let .notAttempted(reason):
                        Text(reason).foregroundStyle(.secondary)
                    case let .failed(message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Query Runtime Now…") { confirmQuery = true }
                            .disabled(status.runtimeState != .ready || model.busyAction != nil)
                    }
                } header: {
                    Text("Runtime devices and clients")
                } footer: {
                    Text("Read through libmonado only while the service is running and listening. Threshold XR never connects when that could start Monado.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    PlaceholderNotice(
                        title: "Headset controls are planned",
                        message: "Brightness, recentring, floor calibration and controller status will use libmonado in a later milestone."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Query Monado now?", isPresented: $confirmQuery) {
            Button("Query") { model.perform(.query) }
        } message: {
            Text("Threshold XR will briefly connect as a Monado client. If no other application is connected and idle exit is on, Monado will stop a few seconds afterwards.")
        }
    }
}
