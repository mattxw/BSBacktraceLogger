//
//  main.swift
//  BacktraceDemo
//
//  Demonstrates capturing the main thread from a watchdog thread while the
//  main thread is busy.
//

import Foundation
import BSBacktraceLogger

print("Current thread:\n")
print(BSLogger.bs_backtraceOfCurrentThread() ?? "No current-thread backtrace available.")
print("\nSimulating a 2 second main-thread stall...\n")

let watchdog = Thread {
    Thread.sleep(forTimeInterval: 0.5)
    print("Main thread backtrace captured by the watchdog:\n")
    print(BSLogger.bs_backtraceOfMainThread() ?? "No main-thread backtrace available.")
}
watchdog.name = "BacktraceDemo.watchdog"
watchdog.start()

simulateMainThreadStall(for: 2)

@inline(never)
func simulateMainThreadStall(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        // Busy main thread, as in a real hang.
    }
}
