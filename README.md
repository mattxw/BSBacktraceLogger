# BSBacktraceLogger

A lightweight backtrace logger that can capture the call stack of any thread in
your process. It is small enough to leave enabled in debug builds and is useful
for diagnosing main-thread hangs from a watchdog thread.

## Requirements

- iOS 15.0+ or macOS 12.0+
- Xcode 16+ (Swift 6 toolchain)
- 64-bit targets (`arm64` or `x86_64`)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mattxw/BSBacktraceLogger.git", from: "1.0.0")
]
```

> Until a release tag is published, substitute `.branch("master")` for
> `from: "1.0.0"`.

Then add the product to your target:

```swift
.target(
    name: "App",
    dependencies: [
        .product(name: "BSBacktraceLogger", package: "BSBacktraceLogger")
    ]
)
```

Or add it in Xcode with **File → Add Package Dependencies…**.

## Usage

### Objective-C

```objc
#import <BSBacktraceLogger/BSLogger.h>

- (void)viewDidLoad {
    [super viewDidLoad];

    BSLOG;       // Log the current thread's backtrace.
    BSLOG_MAIN;  // Log the main thread's backtrace.
    BSLOG_ALL;   // Log every thread's backtrace.
}
```

The macros are convenience wrappers around `NSLog`. The underlying methods can
also be used directly:

```objc
NSString *backtrace = [BSLogger bs_backtraceOfCurrentThread];
NSString *mainBacktrace = [BSLogger bs_backtraceOfMainThread];
NSString *allBacktraces = [BSLogger bs_backtraceOfAllThread];
NSString *threadBacktrace = [BSLogger bs_backtraceOfNSThread:someThread];
```

### Swift

```swift
import BSBacktraceLogger

let current = BSLogger.bs_backtraceOfCurrentThread()
let main = BSLogger.bs_backtraceOfMainThread()
let all = BSLogger.bs_backtraceOfAllThread()
let other = BSLogger.bs_backtrace(of: thread)
```

The `BSLOG*` macros are Objective-C only; in Swift, use the class methods above.

### Capturing the main thread from a watchdog

```swift
let watchdog = Thread {
    let backtrace = BSLogger.bs_backtraceOfMainThread()
    print(backtrace ?? "No backtrace available")
}
watchdog.name = "Watchdog"
watchdog.start()
```

Run the bundled demo to see this in action:

```sh
swift run BacktraceDemo
```

Example output:

```text
Backtrace of Thread 259:
libsystem_kernel.dylib          0x19bcd90f8 mach_absolute_time + 108
libsystem_kernel.dylib          0x19bcdac20 __commpage_gettimeofday_internal + 44
libsystem_c.dylib               0x19bbabefc gettimeofday + 56
libsystem_c.dylib               0x19bbb41c4 clock_gettime + 256
Foundation                      0x19ddd004c $s10Foundation4DateV3nowACvgZTm + 56
BacktraceDemo                   0x1021fe4b8 $s13BacktraceDemo23simulateMainThreadStall3forySd_tF + 216
BacktraceDemo                   0x1021fe008 main + 868
```

Each line contains the image name, address, symbol name (when available), and
the offset into the symbol or image. Swift symbols are reported using their
mangled names (for example `$s13BacktraceDemo…`); pipe them through
`swift demangle` if you need a readable form.

## Thread resolution

- The **current** and **main** threads are always supported.
- Any other `NSThread` can only be resolved when it has a unique name that was
  assigned **before the thread was started**. Foundation copies that name to
  the underlying pthread at start time, which lets the logger match the thread.
  If the thread is unnamed, `bs_backtraceOfNSThread:` returns a failure string
  instead of guessing.

## Limitations

- Only threads in the current process can be inspected.
- Backtraces are built by walking frame pointers. Do not build with
  `-fomit-frame-pointer` if you rely on this library. Apple's arm64 default
  keeps frame pointers.
- Symbol names are read from the Mach-O symbol tables at runtime. Release and
  App Store builds may strip local symbols, in which case only the image and
  an address/offset are available. Use the device's dSYM and the Console app
  for fully symbolicated crash logs.
- Capture is not async-signal-safe. Do not call it from a signal handler.
- Symbolication walks the symbol table for every frame, so avoid calling this
  from performance-sensitive hot paths.

## Migration notes

- The Xcode project and the storyboard-based example app were replaced by the
  Swift package and the command-line `BacktraceDemo` executable.
- The `BSLogger+Swift.swift` convenience extension (an instance method named
  `print()`) was removed. Use the class methods instead.
- The `BSLOG*` macros now work and no longer carry a trailing semicolon.
- `BSBacktraceLoggerVersionNumber` and `BSBacktraceLoggerVersionString` are now
  defined and can be linked against.

## Build and test

```sh
swift build
swift test
swift run BacktraceDemo
```

## License

GPL-3.0. See [LICENSE](LICENSE).
