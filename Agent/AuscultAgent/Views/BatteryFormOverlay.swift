import SwiftUI

/// Collects Maximum Capacity (and Cycle Count, where Settings shows one).
///
/// Tailored to the model: it names the exact Settings path — "Battery Health"
/// on iPhone 15 and later, "Battery Health & Charging" before that — and only
/// asks for a cycle count where Settings actually displays one, so nobody is
/// sent looking for a figure their phone does not have.
struct BatteryFormOverlay: View {
    let form: BatteryForm
    @State private var capacity = ""
    @State private var cycles = ""

    private var coordinator: InteractionCoordinator { .shared }

    private var capacityValue: Int? {
        Int(capacity).flatMap { (1...100).contains($0) ? $0 : nil }
    }
    private var cyclesValue: Int? {
        Int(cycles).flatMap { (0...5000).contains($0) ? $0 : nil }
    }
    /// false = this model shows no cycle count; nil = unknown (iPad).
    private var cyclesShown: Bool? { form.rating?.cycleCountInSettings }
    private var path: String { form.rating?.settingsPath ?? "Settings › Battery" }

    private var canSubmit: Bool {
        capacityValue != nil && (cycles.isEmpty || cyclesValue != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("iOS doesn't let apps read battery health, so Auscult uses the "
                         + "figures Settings shows — then tells you what they mean for your "
                         + "\(form.modelName).")
                        .font(.callout)
                }

                Section("Where to find them") {
                    Label("Open \(path)", systemImage: "1.circle")
                    Label(cyclesShown == true
                            ? "Note Maximum Capacity and Cycle Count"
                            : cyclesShown == false
                                ? "Note Maximum Capacity"
                                : "Note Maximum Capacity, and Cycle Count if it's shown",
                          systemImage: "2.circle")
                    Label("Come back here and enter them", systemImage: "3.circle")
                }

                Section {
                    LabeledContent("Maximum Capacity") {
                        HStack(spacing: 4) {
                            TextField("e.g. 92", text: $capacity)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                    if cyclesShown != false {
                        LabeledContent(cyclesShown == true ? "Cycle Count" : "Cycle Count (if shown)") {
                            TextField("e.g. 310", text: $cycles)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    if !capacity.isEmpty && capacityValue == nil {
                        Text("Maximum Capacity is a percentage between 1 and 100.")
                            .foregroundStyle(.red)
                    } else if cyclesShown == false {
                        Text("This model doesn't show a cycle count in Settings — Maximum "
                             + "Capacity is enough.")
                    }
                }

                Section {
                    Text("For a precise reading with no typing, connect this device to Auscult "
                         + "on a Mac over USB — it reads the battery directly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Battery Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { coordinator.submitBattery(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Check") {
                        guard let cap = capacityValue else { return }
                        coordinator.submitBattery(BatteryEntry(
                            capacity: cap, cycles: cycles.isEmpty ? nil : cyclesValue))
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                }
            }
        }
    }
}
