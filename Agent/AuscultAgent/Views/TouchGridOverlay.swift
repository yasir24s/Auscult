import SwiftUI
import UIKit

/// The traced-grid overlay for the digitizer test.
struct TouchGridOverlay: View {
    let grid: TouchGrid
    @Environment(InteractionCoordinator.self) private var coordinator

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Cells light up as they register, so the person can see what
                // they've still to cover — and, if a region is dead, watch it
                // stay dark no matter how hard they rub it.
                VStack(spacing: 1) {
                    ForEach(0..<grid.rows, id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<grid.columns, id: \.self) { column in
                                let hit = grid.touched.contains(
                                    TouchGrid.Cell(row: row, column: column)
                                )
                                Rectangle()
                                    .fill(hit ? Color.green.opacity(0.75) : Color.white.opacity(0.10))
                                    .overlay(Rectangle().stroke(.white.opacity(0.20), lineWidth: 0.5))
                            }
                        }
                    }
                }
                .ignoresSafeArea()

                // The actual touch capture sits on top of the visuals.
                MultiTouchSurface(rows: grid.rows, columns: grid.columns) { row, col, simultaneous in
                    coordinator.registerTouch(row: row, column: col, maxSimultaneous: simultaneous)
                }
                .ignoresSafeArea()

                VStack {
                    HStack {
                        Text("\(grid.touched.count) / \(grid.total)")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Button("Finish") { coordinator.finishTouchGrid() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    Text("Drag a finger over every square")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.top, geo.safeAreaInsets.top)
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}

/// Reports every touch and how many fingers were down at once.
///
/// SwiftUI's `DragGesture` follows a single finger, so the maximum-simultaneous
/// -touches figure — and reliable coverage while several fingers move together
/// — needs raw UIKit touch handling.
private struct MultiTouchSurface: UIViewRepresentable {
    let rows: Int
    let columns: Int
    let onTouch: (Int, Int, Int) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.rows = rows
        view.columns = columns
        view.onTouch = onTouch
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.rows = rows
        view.columns = columns
        view.onTouch = onTouch
    }

    final class TouchView: UIView {
        var rows = 1
        var columns = 1
        var onTouch: ((Int, Int, Int) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            report(touches, event)
        }

        private func report(_ touches: Set<UITouch>, _ event: UIEvent?) {
            // `event.allTouches` is the true concurrent count; `touches` only
            // holds the ones that changed in this callback.
            let simultaneous = event?.allTouches?.filter {
                $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
            }.count ?? touches.count

            for touch in touches {
                let p = touch.location(in: self)
                guard bounds.contains(p), bounds.width > 0, bounds.height > 0 else { continue }
                let column = min(Int(p.x / bounds.width * CGFloat(columns)), columns - 1)
                let row = min(Int(p.y / bounds.height * CGFloat(rows)), rows - 1)
                guard row >= 0, column >= 0 else { continue }
                onTouch?(row, column, simultaneous)
            }
        }
    }
}
