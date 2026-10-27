//
//  BSLoggerTests.swift
//  BSBacktraceLogger
//

import Foundation
import Testing

@testable import BSBacktraceLogger

/// Parks the calling thread on `semaphore` so its backtrace contains a
/// deterministic, test-specific symbol.
@inline(never)
private func parkOnSemaphore(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// Captures the backtrace of the calling thread from a dedicated frame so the
/// symbolication path can be asserted.
@inline(never)
private func captureBacktraceFromMarkerFrame() -> String? {
    BSLogger.bs_backtraceOfCurrentThread()
}

@Suite(.serialized)
struct BSLoggerTests {

    @Test
    func currentThreadProducesFormattedBacktrace() {
        let backtrace = BSLogger.bs_backtraceOfCurrentThread()

        #expect(backtrace?.contains("Backtrace of Thread") == true)
        #expect(backtrace?.contains(" 0x") == true)
        #expect(backtrace?.contains(" + ") == true)
    }

    @Test
    func currentThreadBacktraceIsSymbolicated() {
        let backtrace = captureBacktraceFromMarkerFrame()

        // Unsymbolicated entries fall back to printing an image address, so a
        // mangled Swift symbol only appears when the symbol table lookup worked.
        #expect(backtrace?.contains("captureBacktraceFromMarkerFrame") == true)
    }

    @Test
    func mainThreadCanBeCapturedFromBackgroundTask() async {
        let backtrace = await Task.detached {
            BSLogger.bs_backtraceOfMainThread()
        }.value

        #expect(backtrace?.contains("Backtrace of Thread") == true)
        // A background thread's stack never reaches the executable's main(),
        // so this also proves the cached main-thread port is used instead of
        // silently falling back to the calling thread.
        #expect(backtrace?.contains("main + ") == true)
    }

    @Test
    func allThreadsCaptureIncludesRunningThreads() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let worker = Thread {
            ready.signal()
            parkOnSemaphore(release)
        }
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtraceOfAllThread()

        #expect(backtrace?.contains("Call Backtrace of") == true)
        #expect(backtrace?.contains("Backtrace of Thread") == true)
    }

    @Test
    func namedThreadIsFound() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let worker = Thread {
            ready.signal()
            parkOnSemaphore(release)
        }
        worker.name = "BSBacktraceLoggerTests.namedWorker"
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtrace(of: worker)

        #expect(backtrace?.contains("Backtrace of Thread") == true)
        // The worker is parked in the marker function, so seeing its symbol
        // proves the captured stack belongs to that thread.
        #expect(backtrace?.contains("parkOnSemaphore") == true)
    }

    @Test
    func unnamedThreadIsNotMisreportedAsCurrentThread() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let worker = Thread {
            ready.signal()
            parkOnSemaphore(release)
        }
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtrace(of: worker)

        // The old implementation silently returned the caller's stack here.
        #expect(backtrace?.contains("Fail to get information about thread") == true)
        #expect(backtrace?.contains("Backtrace of Thread") == false)
    }

    @Test
    func repeatedCapturesRemainStable() {
        for _ in 0..<10 {
            #expect(BSLogger.bs_backtraceOfCurrentThread() != nil)
        }
    }
}
