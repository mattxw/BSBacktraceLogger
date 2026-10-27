//
//  BSLogger.h
//  BSBacktraceLogger
//
//  Created by Ruswan Efendi on 29/03/22.
//  Copyright © 2022 Ruswan Efendi. All rights reserved.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Logs the backtrace of the current thread.
#define BSLOG NSLog(@"%@", [BSLogger bs_backtraceOfCurrentThread])

/// Logs the backtrace of the main thread.
#define BSLOG_MAIN NSLog(@"%@", [BSLogger bs_backtraceOfMainThread])

/// Logs the backtraces of every thread in the process.
#define BSLOG_ALL NSLog(@"%@", [BSLogger bs_backtraceOfAllThread])

@interface BSLogger : NSObject

/// Returns a human-readable backtrace of every thread in the process,
/// or a failure description if the threads cannot be inspected.
+ (nullable NSString *)bs_backtraceOfAllThread;

/// Returns a human-readable backtrace of the calling thread.
+ (nullable NSString *)bs_backtraceOfCurrentThread;

/// Returns a human-readable backtrace of the main thread.
+ (nullable NSString *)bs_backtraceOfMainThread;

/// Returns a human-readable backtrace of `thread`.
///
/// The current thread and the main thread are always supported. Any other
/// thread can only be resolved when it has a unique name that was assigned
/// before the thread was started; otherwise a failure description is returned.
+ (nullable NSString *)bs_backtraceOfNSThread:(NSThread *)thread;

@end

NS_ASSUME_NONNULL_END
