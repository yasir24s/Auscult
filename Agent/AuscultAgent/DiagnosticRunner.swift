import Foundation
import UIKit

/// Runs tests. Knows nothing about the host link.
///
/// Splitting this out of `AgentServer` is what lets the agent be useful on its
/// own: the tests never needed a Mac, but the code that drove them was welded
/// to the socket, so the app could not run a single check without one. The
/// host path now goes through here too, via the `on…` hooks, so there is one
/// implementation of the awkward parts rather than two that drift.
@MainActor
@Observable
final class DiagnosticRunner {
    enum State: Equatable {
        case idle
        case running(testID: String, title: String, fraction: Double, message: String)

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    private(set) var state: State = .idle
    /// Latest result per test, newest run replacing the old one.
    private(set) var results: [AgentTestResult] = []
    private(set) var userPrompt: UserPrompt?
    /// Set while `runAll` is working through the catalogue.
    private(set) var sweepRemaining: Int = 0

    private let registry = TestRegistry()
    private var runTask: Task<Void, Never>?
    private var promptContinuation: CheckedContinuation<PromptAnswer, Never>?

    /// Hooks the host link fills in. All nil when running standalone, which is
    /// the whole point — nothing here needs a connection to work.
    var onStarted: ((AgentTestDescriptor) -> Void)?
    var onProgress: ((AgentProgress) -> Void)?
    var onFinished: ((AgentTestResult) -> Void)?
    var onCancelled: (() -> Void)?
    var onNote: ((String, Bool) -> Void)?

    var catalogue: [AgentTestDescriptor] { registry.catalogue() }

    func descriptor(for id: String) -> AgentTestDescriptor? {
        registry.test(withID: id)?.descriptor
    }

    func result(for id: String) -> AgentTestResult? {
        results.first { $0.testID == id }
    }

    // MARK: Running

    /// Run every test that can run without somebody watching the screen.
    ///
    /// Interactive tests are excluded deliberately. Each one blocks on a person
    /// and gives up after 45s, so including them would turn an unattended sweep
    /// into several minutes of timeouts reported as failures. They stay
    /// individually runnable.
    func runAll() {
        let queue = catalogue.filter { $0.isRunnable && !$0.requiresInteraction }
        guard !queue.isEmpty else { return }
        runTask?.cancel()
        sweepRemaining = queue.count

        runTask = Task { @MainActor [weak self] in
            for descriptor in queue {
                guard let self, !Task.isCancelled else { break }
                await self.execute(descriptor)
                self.sweepRemaining -= 1
            }
            self?.sweepRemaining = 0
            self?.state = .idle
        }
    }

    func run(testID: String) {
        guard let descriptor = descriptor(for: testID) else {
            onNote?("No such test: \(testID)", true)
            return
        }
        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            await self?.execute(descriptor)
            self?.state = .idle
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        sweepRemaining = 0
        resolvePrompt(.timedOut)
        UIApplication.shared.isIdleTimerDisabled = false
        state = .idle
        onCancelled?()
    }

    /// Run one test to completion and record the result.
    private func execute(_ descriptor: AgentTestDescriptor) async {
        guard let test = registry.test(withID: descriptor.id) else { return }
        let testID = descriptor.id
        let started = Date()

        state = .running(testID: testID, title: descriptor.title, fraction: 0, message: "Starting")
        onStarted?(descriptor)
        onNote?("Running \(descriptor.title)", false)
        // Only for the duration of this test. Holding the screen awake for a
        // whole session costs a couple of watts on a large panel, which would
        // corrupt the very drain measurements this tool exists to take.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var result: AgentTestResult
        do {
            // Detached, NOT @MainActor. The compute and thermal tests saturate
            // every core for seconds; on the main actor that blocks the run
            // loop and iOS's watchdog kills the app outright. UI work hops back
            // explicitly.
            result = try await Task.detached(priority: .userInitiated) { [weak self] in
                try await test.run(context: AgentTestContext(
                    progress: { fraction, message in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.state = .running(
                                testID: testID, title: descriptor.title,
                                fraction: fraction, message: message
                            )
                            self.onProgress?(AgentProgress(
                                testID: testID, fraction: fraction, message: message
                            ))
                        }
                    },
                    askUser: { prompt in
                        await self?.askUser(prompt, testID: testID) ?? .timedOut
                    },
                    awaitingUser: { message in
                        Task { @MainActor [weak self] in
                            self?.onProgress?(AgentProgress(
                                testID: testID, fraction: 0.5,
                                message: message, awaitingUser: true
                            ))
                        }
                    }
                ))
            }.value
        } catch is CancellationError {
            userPrompt = nil
            onCancelled?()
            return
        } catch {
            result = AgentTestResult(
                testID: testID, title: descriptor.title,
                section: descriptor.section, verdict: .error,
                summary: "Test failed unexpectedly",
                detail: error.localizedDescription
            )
        }
        result.duration = Date().timeIntervalSince(started)

        results.removeAll { $0.testID == result.testID }
        results.append(result)
        userPrompt = nil
        onFinished?(result)
    }

    // MARK: Prompts

    func askUser(
        _ prompt: UserPrompt, testID: String, timeout: TimeInterval = 45
    ) async -> PromptAnswer {
        onProgress?(AgentProgress(
            testID: testID, fraction: 0.5, message: prompt.message, awaitingUser: true
        ))
        userPrompt = prompt

        let answer = await withCheckedContinuation { (c: CheckedContinuation<PromptAnswer, Never>) in
            promptContinuation = c
            // Give up on our own schedule rather than waiting forever on
            // somebody who has put the device down.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resolvePrompt(.timedOut)
            }
        }
        userPrompt = nil
        return answer
    }

    /// Called from the UI when the person answers.
    func answerPrompt(_ confirmed: Bool) {
        resolvePrompt(confirmed ? .confirmed : .rejected)
    }

    private func resolvePrompt(_ answer: PromptAnswer) {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        userPrompt = nil
        continuation.resume(returning: answer)
    }

    // MARK: Summary

    /// Counts by verdict, for the standalone overview.
    var tally: (pass: Int, warn: Int, fail: Int, other: Int) {
        var t = (pass: 0, warn: 0, fail: 0, other: 0)
        for r in results {
            switch r.verdict {
            case .pass: t.pass += 1
            case .warn: t.warn += 1
            case .fail, .error: t.fail += 1
            default: t.other += 1
            }
        }
        return t
    }

    func clearResults() { results.removeAll() }
}

// MARK: - Prompt types

/// Asked of the person holding the device.
///
/// Top-level rather than nested in either `AgentServer` or `DiagnosticRunner`:
/// both raise these, and the tests that construct them should not have to know
/// which one is driving.
struct UserPrompt: Equatable {
    var message: String
    var confirmTitle: String
    var rejectTitle: String?
}

/// How the person answered — or that they never did.
///
/// A distinct `timedOut` case matters: treating "nobody was holding the device"
/// as "the user saw a defect" would report a broken display on perfectly good
/// hardware, which is the worst kind of wrong answer a diagnostic can give.
enum PromptAnswer {
    case confirmed, rejected, timedOut
}
