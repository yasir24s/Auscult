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

                // The drawn grid and the touch surface share ONE container and
                // therefore one frame. They used to be sized separately — the
                // grid ignored the safe area and filled the screen, while the
                // touch view was pinned to GeometryReader's size, which is the
                // safe area. Rows were then drawn over one height and mapped
                // over another: a tester on an iPhone 13 found touches landing
                // late going up and early going down, and horizontal fine,
                // because portrait has no side insets. A digitizer test that
                // credits a touch to the neighbouring square can hide a dead
                // strip, so this is not cosmetic. `mapping` in the result
                // verifies the two frames match on every run.
                ZStack {
                // Cells light up as they register, so the person can see what
                // they've still to cover — and, if a region is dead, watch it
                // stay dark no matter how hard they rub it.
                //
                // Spacing 0 so a drawn cell is exactly height/rows — the same
                // arithmetic TouchView uses. The stroke overlay draws the lines.
                VStack(spacing: 0) {
                    ForEach(0..<grid.rows, id: \.self) { row in
                        HStack(spacing: 0) {
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
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { coordinator.recordFrames(drawn: g.frame(in: .global)) }
                        .onChange(of: g.frame(in: .global)) { _, f in coordinator.recordFrames(drawn: f) }
                })

                // The capture view sits above the visuals. It must be flexible
                // rather than left to its intrinsic size: a plain UIView has
                // none, so SwiftUI can lay it out at zero and no touch ever
                // reaches it. maxWidth/maxHeight fills the shared container —
                // NOT geo.size, which is the safe area and caused the offset.
                MultiTouchSurface(rows: grid.rows, columns: grid.columns, onTouch: { row, col, simultaneous in
                    coordinator.registerTouch(row: row, column: col, maxSimultaneous: simultaneous)
                }, onLayout: { coordinator.recordFrames(touch: $0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .ignoresSafeArea()

                // Only the Finish button may take touches; everything else in
                // this layer must let them through to the capture view beneath.
                VStack(spacing: 4) {
                    HStack {
                        Text("\(grid.touched.count) / \(grid.total)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                        Spacer()
                        Button("Finish") { coordinator.finishTouchGrid() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 20)

                    Text("Drag a finger over every square")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                }
                .padding(.top, geo.safeAreaInsets.top + 6)
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
    /// The surface's frame in window coordinates, for the mapping self-check.
    let onLayout: (CGRect) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.rows = rows
        view.columns = columns
        view.onTouch = onTouch
        view.onLayout = onLayout
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.rows = rows
        view.columns = columns
        view.onTouch = onTouch
        view.onLayout = onLayout
    }

    final class TouchView: UIView {
        var rows = 1
        var columns = 1
        var onTouch: ((Int, Int, Int) -> Void)?
        var onLayout: ((CGRect) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            // nil target = window coordinates, which is the same space as
            // SwiftUI's .global — so this compares like with like.
            guard window != nil, bounds.width > 0 else { return }
            let frame = convert(bounds, to: nil)
            DispatchQueue.main.async { [weak self] in self?.onLayout?(frame) }
        }

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
