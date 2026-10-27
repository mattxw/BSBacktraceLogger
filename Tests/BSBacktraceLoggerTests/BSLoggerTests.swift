//
//  BSLoggerTests.swift
//  BSBacktraceLogger
//

import Foundation
import Testing

@testable import BSBacktraceLogger

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
    func mainThreadCanBeCapturedFromBackgroundTask() async {
        let backtrace = await Task.detached {
            BSLogger.bs_backtraceOfMainThread()
        }.value

        #expect(backtrace?.contains("Backtrace of Thread") == true)
    }

    @Test
    func allThreadsCaptureIncludesRunningThreads() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let worker = Thread {
            ready.signal()
            release.wait()
        }
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtraceOfAllThread()
        release.signal()

        #expect(backtrace?.contains("Call Backtrace of") == true)
        #expect(backtrace?.contains("Backtrace of Thread") == true)
    }

    @Test
    func namedThreadIsFound() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let worker = Thread {
            ready.signal()
            release.wait()
        }
        worker.name = "BSBacktraceLoggerTests.namedWorker"
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtrace(of: worker)
        release.signal()

        #expect(backtrace?.contains("Backtrace of Thread") == true)
    }

    @Test
    func unnamedThreadIsNotMisreportedAsCurrentThread() {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let worker = Thread {
            ready.signal()
            release.wait()
        }
        worker.start()
        #expect(ready.wait(timeout: .now() + 5) == .success)

        let backtrace = BSLogger.bs_backtrace(of: worker)
        release.signal()

        // The old implementation silently returned the caller's stack here.
        #expect(backtrace?.contains("Fail to get information about thread") == true)
    }

    @Test
    func repeatedCapturesRemainStable() {
        for _ in 0..<10 {
            #expect(BSLogger.bs_backtraceOfCurrentThread() != nil)
        }
    }
}
