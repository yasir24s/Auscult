import Foundation
import SwiftUI

/// Owns whatever the guided tests need to put on the screen.
///
/// The tests themselves stay free of SwiftUI: they set a mode here and await a
/// result, and the view layer renders whatever the current mode says. That keeps
/// a dead-pixel sweep — which is really "fill the display with one colour and
/// ask a human" — expressible as a linear async function.
@MainActor
@Observable
final class InteractionCoordinator {
    /// Reachable from any actor. The class is `@MainActor`, so every *member*
    /// still requires the main actor — only the reference itself crosses, and a
    /// global-actor-isolated class is implicitly Sendable. Without this the
    /// tests, which are nonisolated async, cannot even name the singleton.
    nonisolated static let shared = InteractionCoordinator()

    enum Mode: Equatable {
        case idle
        /// Fill the screen with a flat colour for visual inspection.
        case solidColour(name: String, colour: SweepColour)
        /// Grid the person must trace over so every cell registers a touch.
        case touchGrid(TouchGrid)
        /// Ask for the battery figures only Settings can show.
        case batteryForm(BatteryForm)

        /// A colour field or a grid must own every pixel; a form must not
        /// hide the status bar, or the person loses the clock and battery.
        var takesOverScreen: Bool {
            switch self {
            case .solidColour, .touchGrid: true
            case .idle, .batteryForm: false
            }
        }
    }

    private(set) var mode: Mode = .idle

    nonisolated private init() {}

    // MARK: Colour sweep

    func showColour(_ colour: SweepColour, named name: String) {
        mode = .solidColour(name: name, colour: colour)
    }

    func hide() { mode = .idle }

    // MARK: Touch grid

    private var gridContinuation: CheckedContinuation<TouchGrid, Never>?

    /// Present the grid and wait until every cell is touched or time runs out.
    func runTouchGrid(rows: Int, columns: Int, timeout: TimeInterval) async -> TouchGrid {
        var grid = TouchGrid(rows: rows, columns: columns)
        grid.deadline = Date().addingTimeInterval(timeout)
        mode = .touchGrid(grid)

        let finished = await withCheckedContinuation { (c: CheckedContinuation<TouchGrid, Never>) in
            gridContinuation = c
            // Give up on our own schedule so a test can never hang forever
            // waiting for someone who has walked away.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finishTouchGrid()
            }
        }
        mode = .idle
        return finished
    }

    /// Called by the view as cells are touched.
    func registerTouch(row: Int, column: Int, maxSimultaneous: Int) {
        guard case .touchGrid(var grid) = mode else { return }
        grid.rawEvents += 1
        grid.touched.insert(TouchGrid.Cell(row: row, column: column))
        grid.maxSimultaneousTouches = max(grid.maxSimultaneousTouches, maxSimultaneous)
        mode = .touchGrid(grid)
        if grid.isComplete { finishTouchGrid() }
    }

    /// Called by the overlay once the grid and the touch surface have laid out.
    /// Equality-guarded so a re-render caused by the write cannot loop.
    func recordFrames(drawn: CGRect? = nil, touch: CGRect? = nil) {
        guard case .touchGrid(var grid) = mode else { return }
        var changed = false
        if let drawn, grid.drawnFrame != drawn { grid.drawnFrame = drawn; changed = true }
        if let touch, grid.touchFrame != touch { grid.touchFrame = touch; changed = true }
        if changed { mode = .touchGrid(grid) }
    }

    /// Stop pressed mid-test: remove whatever is on screen now. The grid's
    /// continuation is resumed so its test unwinds rather than waiting out its
    /// timeout; the runner discards what it returns.
    func dismissForCancellation() {
        finishTouchGrid()
        submitBattery(nil)
        mode = .idle
    }

    // MARK: Battery form

    private var batteryContinuation: CheckedContinuation<BatteryEntry?, Never>?

    /// Show the form and wait for the figures, or nil if skipped. Five minutes,
    /// not the usual 45 s: the person has to go to Settings and come back.
    func runBatteryForm(_ form: BatteryForm, timeout: TimeInterval = 300) async -> BatteryEntry? {
        mode = .batteryForm(form)
        let entry = await withCheckedContinuation { (c: CheckedContinuation<BatteryEntry?, Never>) in
            batteryContinuation = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.submitBattery(nil)
            }
        }
        mode = .idle
        return entry
    }

    func submitBattery(_ entry: BatteryEntry?) {
        guard let c = batteryContinuation else { return }
        batteryContinuation = nil
        c.resume(returning: entry)
    }

    func finishTouchGrid() {
        guard let continuation = gridContinuation else { return }
        gridContinuation = nil
        if case .touchGrid(let grid) = mode {
            continuation.resume(returning: grid)
        } else {
            continuation.resume(returning: TouchGrid(rows: 0, columns: 0))
        }
    }
}

/// Colours used by the dead-pixel sweep.
///
/// Pure primaries are what actually reveal a fault: a stuck subpixel is
/// invisible on white but obvious on the two colours that should leave it dark.
enum SweepColour: String, CaseIterable, Equatable {
    case red, green, blue, white, black

    var colour: Color {
        switch self {
        case .red: .init(red: 1, green: 0, blue: 0)
        case .green: .init(red: 0, green: 1, blue: 0)
        case .blue: .init(red: 0, green: 0, blue: 1)
        case .white: .white
        case .black: .black
        }
    }

    /// What a healthy panel should look like, phrased for the person looking.
    var expectation: String {
        switch self {
        case .red: "an even red with no dark or bright specks"
        case .green: "an even green with no dark or bright specks"
        case .blue: "an even blue with no dark or bright specks"
        case .white: "an even white with no tint, blotches or dark pixels"
        case .black: "a true black with no glowing pixels or backlight bleed"
        }
    }
}

struct BatteryForm: Equatable {
    let modelName: String
    let rating: BatteryGuide.Rating?
}

struct BatteryEntry: Equatable {
    let capacity: Int
    let cycles: Int?
}

struct TouchGrid: Equatable {
    struct Cell: Hashable { let row: Int; let column: Int }

    var rows: Int
    var columns: Int
    var touched: Set<Cell> = []
    var maxSimultaneousTouches: Int = 0
    /// Raw touch callbacks received, regardless of where they landed.
    /// Zero here means the capture view never saw the finger at all, which is a
    /// layout problem on our side rather than a fault in the digitizer.
    var rawEvents: Int = 0
    var deadline: Date = .distantFuture
    /// Where the grid was drawn and where touches were mapped, both in window
    /// coordinates. They must be the same rectangle: if they differ, a finger
    /// on one square is credited to its neighbour, which can make a dead strip
    /// of digitizer look alive. They once differed by the safe-area insets.
    var drawnFrame: CGRect?
    var touchFrame: CGRect?

    var total: Int { rows * columns }
    var isComplete: Bool { total > 0 && touched.count >= total }
    var coverage: Double { total == 0 ? 0 : Double(touched.count) / Double(total) * 100 }

    /// Cells never registered, as human-readable coordinates.
    var missed: [String] {
        guard total > 0 else { return [] }
        var out: [String] = []
        for r in 0..<rows {
            for c in 0..<columns where !touched.contains(Cell(row: r, column: c)) {
                out.append("r\(r + 1)c\(c + 1)")
            }
        }
        return out
    }
}
