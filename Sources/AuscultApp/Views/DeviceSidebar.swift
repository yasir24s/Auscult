import SwiftUI
import AuscultKit

struct DeviceSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(
            get: { model.selectedDeviceID },
            set: { model.selectedDeviceID = $0 }
        )) {
            Section("Devices") {
                if model.visibleDevices.isEmpty {
                    Text(model.isDiscovering ? "Scanning…" : "None found")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.visibleDevices) { device in
                        DeviceRow(
                            device: device,
                            verdict: model.reports[device.id]?.overallVerdict,
                            isReachable: model.isReachable(device)
                        )
                        .tag(device.id)
                    }
                }
            }

            Section("Data Paths") {
                ForEach(model.transports) { t in
                    HStack(spacing: 6) {
                        Image(systemName: t.availability.isAvailable
                              ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(t.availability.isAvailable ? .green : .secondary)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.caption)
                            if let sub = t.availability.version ?? t.availability.detail {
                                Text(sub)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            if !model.discoveryErrors.isEmpty {
                Section("Discovery Warnings") {
                    ForEach(model.discoveryErrors, id: \.self) { e in
                        Text(e).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Toggle("Show simulators", isOn: Binding(
                    get: { model.showSimulators },
                    set: { model.showSimulators = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)

                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack(spacing: 5) {
                        if model.isDiscovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(model.isDiscovering ? "Scanning" : "Rescan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isDiscovering)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct DeviceRow: View {
    let device: DeviceSnapshot
    let verdict: Verdict?
    let isReachable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbolName)
                .font(.title3)
                .foregroundStyle(isReachable ? .primary : .tertiary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .lineLimit(1)
                Text(device.osDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if device.isSimulator { Tag("sim", .gray) }
                    if device.isPrereleaseOS { Tag("beta", .purple) }
                    if !isReachable { Tag("offline", .orange) }
                    else if device.link == .usb { Tag("usb", .blue) }
                    else { Tag("wi-fi", .teal) }
                }
            }

            Spacer(minLength: 0)

            if let verdict {
                Text(verdict.symbol)
                    .font(.headline)
                    .foregroundStyle(verdict.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: .rect(cornerRadius: 3))
            .foregroundStyle(color)
    }
}

extension DeviceSnapshot {
    var symbolName: String {
        switch family {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .iPod: "ipodtouch"
        case .appleTV: "appletv"
        case .appleWatch: "applewatch"
        case .appleVision: "visionpro"
        case .mac: "desktopcomputer"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

extension Verdict {
    var tint: Color {
        switch self {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .error: .purple
        case .info: .secondary
        case .unsupported, .skipped: .secondary
        }
    }
}
