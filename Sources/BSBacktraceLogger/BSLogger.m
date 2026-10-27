//
//  BSBacktraceLogger.m
//  BSBacktraceLogger
//
//  Created by 张星宇 on 16/8/27.
//  Copyright © 2022 Ruswan Efendi. All rights reserved.
//

#import "BSBacktraceLogger.h"

#import <dlfcn.h>
#import <inttypes.h>
#import <limits.h>
#import <mach/mach.h>
#import <mach-o/arch.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <sys/types.h>

//! Project version number for BSBacktraceLogger.
double BSBacktraceLoggerVersionNumber = 1.0;

//! Project version string for BSBacktraceLogger.
const unsigned char BSBacktraceLoggerVersionString[] = "1.0.0";

#pragma mark - Constants

#define BS_MAX_BACKTRACE_LENGTH 50
#define BS_MAX_THREAD_NAME_LENGTH 256

// arm64e stores pointer authentication bits in the upper bits of a pointer.
// They must be stripped before the address can be symbolicated.
#define BS_ARM64E_POINTER_MASK 0x0000000FFFFFFFFFULL

#pragma mark - Architecture support

#if defined(__arm64__)
#define BS_THREAD_STATE_COUNT ARM_THREAD_STATE64_COUNT
#define BS_THREAD_STATE ARM_THREAD_STATE64
#define BS_FRAME_POINTER __fp
#define BS_INSTRUCTION_ADDRESS __pc
#define BS_DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(3UL))
#elif defined(__x86_64__)
#define BS_THREAD_STATE_COUNT x86_THREAD_STATE64_COUNT
#define BS_THREAD_STATE x86_THREAD_STATE64
#define BS_FRAME_POINTER __rbp
#define BS_INSTRUCTION_ADDRESS __rip
#define BS_DETAG_INSTRUCTION_ADDRESS(A) (A)
#else
#error BSBacktraceLogger requires a 64-bit arm64 or x86_64 target.
#endif

#define BS_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A) (BS_DETAG_INSTRUCTION_ADDRESS((A)) - 1)

typedef struct nlist_64 BS_NLIST;

typedef struct BSStackFrameEntry {
    struct BSStackFrameEntry *previous;
    uintptr_t return_address;
} BSStackFrameEntry;

static mach_port_t main_thread_id = MACH_PORT_NULL;

#pragma mark - Forward declarations

static uintptr_t bs_normaliseInstructionPointer(uintptr_t instructionPointer);
static NSString *bs_backtraceOfMachThread(thread_t thread);
static BOOL bs_machThreadFromNSThread(NSThread *nsthread, thread_t *outThread, BOOL *outOwnsThread);
static bool bs_fillThreadStateIntoMachineContext(thread_t thread, _STRUCT_MCONTEXT *machineContext);
static uintptr_t bs_mach_framePointer(mcontext_t const machineContext);
static uintptr_t bs_mach_instructionAddress(mcontext_t const machineContext);
static uintptr_t bs_mach_linkRegister(mcontext_t const machineContext);
static kern_return_t bs_mach_copyMem(const void *const src, void *const dst, const size_t numBytes);
static void bs_symbolicate(const uintptr_t *const backtraceBuffer,
                           Dl_info *const symbolsBuffer,
                           const int numEntries,
                           const int skippedEntries);
static bool bs_dladdr(const uintptr_t address, Dl_info *const info);
static const char *bs_lastPathEntry(const char *const path);
static NSString *bs_logBacktraceEntry(const uintptr_t address, const Dl_info *const dlInfo);
static uintptr_t bs_firstCmdAfterHeader(const struct mach_header *const header);
static uint32_t bs_imageIndexContainingAddress(const uintptr_t address);
static uintptr_t bs_segmentBaseOfImageIndex(const uint32_t idx);

#pragma mark - Implementation

@implementation BSLogger

+ (void)load {
    // +load runs on the main thread while images are being loaded, which makes
    // it a safe place to cache the main thread's Mach port.
    main_thread_id = mach_thread_self();
}

#pragma mark - Public API

+ (NSString *)bs_backtraceOfNSThread:(NSThread *)thread {
    thread_t machThread = MACH_PORT_NULL;
    BOOL ownsThread = NO;

    if (!bs_machThreadFromNSThread(thread, &machThread, &ownsThread)) {
        NSString *name = thread.name;
        return [NSString stringWithFormat:@"Fail to get information about thread: %@",
                name.length > 0 ? name : @"<unnamed>"];
    }

    NSString *result = bs_backtraceOfMachThread(machThread);
    if (ownsThread) {
        mach_port_deallocate(mach_task_self(), machThread);
    }
    return result;
}

+ (NSString *)bs_backtraceOfCurrentThread {
    return [self bs_backtraceOfNSThread:[NSThread currentThread]];
}

+ (NSString *)bs_backtraceOfMainThread {
    return [self bs_backtraceOfNSThread:[NSThread mainThread]];
}

+ (NSString *)bs_backtraceOfAllThread {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t thread_count = 0;

    kern_return_t kr = task_threads(mach_task_self(), &threads, &thread_count);
    if (kr != KERN_SUCCESS) {
        return @"Fail to get information of all threads";
    }

    NSMutableString *resultString =
        [NSMutableString stringWithFormat:@"Call Backtrace of %u threads:\n", (unsigned int)thread_count];

    for (mach_msg_type_number_t index = 0; index < thread_count; index++) {
        [resultString appendString:bs_backtraceOfMachThread(threads[index])];
        mach_port_deallocate(mach_task_self(), threads[index]);
    }

    vm_deallocate(mach_task_self(),
                  (vm_address_t)threads,
                  (vm_size_t)(sizeof(thread_act_t) * thread_count));

    return [resultString copy];
}

@end

#pragma mark - Capture

static uintptr_t bs_normaliseInstructionPointer(uintptr_t instructionPointer) {
#if defined(__arm64__)
    const NXArchInfo *info = NXGetLocalArchInfo();
    if (info != NULL && info->cpusubtype == CPU_SUBTYPE_ARM64E) {
        return instructionPointer & BS_ARM64E_POINTER_MASK;
    }
#endif
    return instructionPointer;
}

static NSString *bs_backtraceOfMachThread(thread_t thread) {
    uintptr_t backtraceBuffer[BS_MAX_BACKTRACE_LENGTH] = {0};
    int frameCount = 0;
    NSMutableString *resultString =
        [[NSMutableString alloc] initWithFormat:@"Backtrace of Thread %u:\n", (unsigned int)thread];

    _STRUCT_MCONTEXT machineContext = {0};
    if (!bs_fillThreadStateIntoMachineContext(thread, &machineContext)) {
        return [NSString stringWithFormat:@"Fail to get information about thread: %u", (unsigned int)thread];
    }

    const uintptr_t instructionAddress = bs_normaliseInstructionPointer(bs_mach_instructionAddress(&machineContext));
    if (instructionAddress == 0) {
        return @"Fail to get instruction address";
    }
    backtraceBuffer[frameCount++] = instructionAddress;

    const uintptr_t linkRegister = bs_normaliseInstructionPointer(bs_mach_linkRegister(&machineContext));
    if (linkRegister != 0) {
        backtraceBuffer[frameCount++] = linkRegister;
    }

    BSStackFrameEntry frame = {0};
    const uintptr_t framePointer = bs_mach_framePointer(&machineContext);
    if (framePointer == 0 ||
        bs_mach_copyMem((void *)framePointer, &frame, sizeof(frame)) != KERN_SUCCESS) {
        return @"Fail to get frame pointer";
    }

    uintptr_t previousFramePointer = framePointer;
    while (frameCount < BS_MAX_BACKTRACE_LENGTH) {
        const uintptr_t returnAddress = bs_normaliseInstructionPointer(frame.return_address);
        if (returnAddress == 0) {
            break;
        }

        backtraceBuffer[frameCount++] = returnAddress;

        const uintptr_t nextFramePointer = (uintptr_t)frame.previous;
        if (nextFramePointer == 0 ||
            nextFramePointer <= previousFramePointer ||
            bs_mach_copyMem(frame.previous, &frame, sizeof(frame)) != KERN_SUCCESS) {
            break;
        }
        previousFramePointer = nextFramePointer;
    }

    Dl_info symbolicated[BS_MAX_BACKTRACE_LENGTH] = {0};
    bs_symbolicate(backtraceBuffer, symbolicated, frameCount, 0);

    for (int index = 0; index < frameCount; index++) {
        // Addresses that do not belong to any loaded image cannot be
        // symbolicated; showing them only produces misleading output.
        if (symbolicated[index].dli_fname == NULL) {
            continue;
        }
        [resultString appendString:bs_logBacktraceEntry(backtraceBuffer[index], &symbolicated[index])];
    }
    [resultString appendString:@"\n"];

    return [resultString copy];
}

static BOOL bs_machThreadFromNSThread(NSThread *nsthread, thread_t *outThread, BOOL *outOwnsThread) {
    *outThread = MACH_PORT_NULL;
    *outOwnsThread = NO;

    if (nsthread == nil) {
        return NO;
    }

    if ([nsthread isMainThread]) {
        if (main_thread_id == MACH_PORT_NULL) {
            return NO;
        }
        *outThread = main_thread_id;
        return YES;
    }

    if (nsthread == [NSThread currentThread]) {
        thread_t currentThread = pthread_mach_thread_np(pthread_self());
        if (currentThread == MACH_PORT_NULL) {
            return NO;
        }
        *outThread = currentThread;
        return YES;
    }

    // Foundation only propagates a name to the underlying pthread when the
    // thread starts, so we can match the NSThread against the pthread name
    // without mutating either object.
    NSString *name = [nsthread name];
    if (name.length == 0) {
        return NO;
    }

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) {
        return NO;
    }

    const char *targetName = name.UTF8String;
    BOOL found = NO;

    for (mach_msg_type_number_t index = 0; index < threadCount; index++) {
        pthread_t posixThread = pthread_from_mach_thread_np(threads[index]);
        char threadName[BS_MAX_THREAD_NAME_LENGTH] = {0};

        if (posixThread != NULL &&
            targetName != NULL &&
            pthread_getname_np(posixThread, threadName, sizeof(threadName)) == 0 &&
            strcmp(threadName, targetName) == 0) {
            *outThread = threads[index];
            *outOwnsThread = YES;
            found = YES;
            break;
        }
    }

    for (mach_msg_type_number_t index = 0; index < threadCount; index++) {
        if (!found || threads[index] != *outThread) {
            mach_port_deallocate(mach_task_self(), threads[index]);
        }
    }

    vm_deallocate(mach_task_self(),
                  (vm_address_t)threads,
                  (vm_size_t)(sizeof(thread_act_t) * threadCount));

    return found;
}

#pragma mark - Machine context

static bool bs_fillThreadStateIntoMachineContext(thread_t thread, _STRUCT_MCONTEXT *machineContext) {
    mach_msg_type_number_t state_count = BS_THREAD_STATE_COUNT;
    kern_return_t kr = thread_get_state(thread,
                                        BS_THREAD_STATE,
                                        (thread_state_t)&machineContext->__ss,
                                        &state_count);
    return kr == KERN_SUCCESS;
}

static uintptr_t bs_mach_framePointer(mcontext_t const machineContext) {
    return machineContext->__ss.BS_FRAME_POINTER;
}

static uintptr_t bs_mach_instructionAddress(mcontext_t const machineContext) {
    return machineContext->__ss.BS_INSTRUCTION_ADDRESS;
}

static uintptr_t bs_mach_linkRegister(mcontext_t const machineContext) {
#if defined(__x86_64__)
    return 0;
#else
    return machineContext->__ss.__lr;
#endif
}

static kern_return_t bs_mach_copyMem(const void *const src, void *const dst, const size_t numBytes) {
    vm_size_t bytesCopied = 0;
    return vm_read_overwrite(mach_task_self(),
                             (vm_address_t)src,
                             (vm_size_t)numBytes,
                             (vm_address_t)dst,
                             &bytesCopied);
}

#pragma mark - Symbolication

static void bs_symbolicate(const uintptr_t *const backtraceBuffer,
                           Dl_info *const symbolsBuffer,
                           const int numEntries,
                           const int skippedEntries) {
    int index = 0;

    if (!skippedEntries && index < numEntries) {
        bs_dladdr(backtraceBuffer[index], &symbolsBuffer[index]);
        index++;
    }

    for (; index < numEntries; index++) {
        bs_dladdr(BS_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(backtraceBuffer[index]), &symbolsBuffer[index]);
    }
}

static bool bs_dladdr(const uintptr_t address, Dl_info *const info) {
    info->dli_fname = NULL;
    info->dli_fbase = NULL;
    info->dli_sname = NULL;
    info->dli_saddr = NULL;

    const uint32_t idx = bs_imageIndexContainingAddress(address);
    if (idx == UINT_MAX) {
        return false;
    }

    const struct mach_header *header = _dyld_get_image_header(idx);
    const uintptr_t imageVMAddrSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(idx);
    const uintptr_t addressWithSlide = address - imageVMAddrSlide;
    const uintptr_t segmentBase = bs_segmentBaseOfImageIndex(idx) + imageVMAddrSlide;
    if (segmentBase == 0) {
        return false;
    }

    info->dli_fname = _dyld_get_image_name(idx);
    info->dli_fbase = (void *)header;

    // Find symbol tables and get whichever symbol is closest to the address.
    const BS_NLIST *bestMatch = NULL;
    uintptr_t bestDistance = ULONG_MAX;
    uintptr_t cmdPtr = bs_firstCmdAfterHeader(header);
    if (cmdPtr == 0) {
        return false;
    }

    for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
        const struct load_command *loadCmd = (struct load_command *)cmdPtr;
        if (loadCmd->cmd == LC_SYMTAB) {
            const struct symtab_command *symtabCmd = (struct symtab_command *)cmdPtr;
            const BS_NLIST *symbolTable = (BS_NLIST *)(segmentBase + symtabCmd->symoff);
            const uintptr_t stringTable = segmentBase + symtabCmd->stroff;

            for (uint32_t iSym = 0; iSym < symtabCmd->nsyms; iSym++) {
                // Debug (STAB) entries and unnamed symbols are not useful for
                // symbolication, and their n_value can shadow real symbols.
                if ((symbolTable[iSym].n_type & N_STAB) != 0 ||
                    symbolTable[iSym].n_value == 0) {
                    continue;
                }

                const char *symbolName =
                    (const char *)(stringTable + symbolTable[iSym].n_un.n_strx);
                if (symbolName == NULL || symbolName[0] == '\0' ||
                    (symbolName[0] == '_' && symbolName[1] == '\0')) {
                    continue;
                }

                uintptr_t symbolBase = symbolTable[iSym].n_value;
                uintptr_t currentDistance = addressWithSlide - symbolBase;
                if ((addressWithSlide >= symbolBase) &&
                    (currentDistance <= bestDistance)) {
                    bestMatch = symbolTable + iSym;
                    bestDistance = currentDistance;
                }
            }
            if (bestMatch != NULL) {
                info->dli_saddr = (void *)(bestMatch->n_value + imageVMAddrSlide);
                info->dli_sname = (char *)((intptr_t)stringTable + (intptr_t)bestMatch->n_un.n_strx);
                if (*info->dli_sname == '_') {
                    info->dli_sname++;
                }
                // This happens if all symbols have been stripped.
                if (info->dli_saddr == info->dli_fbase && bestMatch->n_type == 3) {
                    info->dli_sname = NULL;
                }
                break;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return true;
}

static NSString *bs_logBacktraceEntry(const uintptr_t address, const Dl_info *const dlInfo) {
    char imageFallback[32] = {0};
    char symbolFallback[32] = {0};

    const char *fname = bs_lastPathEntry(dlInfo->dli_fname);
    if (fname == NULL) {
        snprintf(imageFallback, sizeof(imageFallback), "0x%" PRIxPTR, (uintptr_t)dlInfo->dli_fbase);
        fname = imageFallback;
    }

    uintptr_t offset = address - (uintptr_t)dlInfo->dli_saddr;
    const char *sname = dlInfo->dli_sname;
    if (sname == NULL) {
        snprintf(symbolFallback, sizeof(symbolFallback), "0x%" PRIxPTR, (uintptr_t)dlInfo->dli_fbase);
        sname = symbolFallback;
        offset = address - (uintptr_t)dlInfo->dli_fbase;
    }

    return [NSString stringWithFormat:@"%-30s  0x%08" PRIxPTR " %s + %" PRIuPTR "\n",
            fname,
            address,
            sname,
            offset];
}

static const char *bs_lastPathEntry(const char *const path) {
    if (path == NULL) {
        return NULL;
    }

    const char *lastFile = strrchr(path, '/');
    return lastFile == NULL ? path : lastFile + 1;
}

#pragma mark - Mach-O helpers

static uintptr_t bs_firstCmdAfterHeader(const struct mach_header *const header) {
    switch (header->magic) {
        case MH_MAGIC:
        case MH_CIGAM:
            return (uintptr_t)(header + 1);
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            return (uintptr_t)(((struct mach_header_64 *)header) + 1);
        default:
            return 0;  // Header is corrupt
    }
}

static uint32_t bs_imageIndexContainingAddress(const uintptr_t address) {
    const uint32_t imageCount = _dyld_image_count();
    const struct mach_header *header = 0;

    for (uint32_t iImg = 0; iImg < imageCount; iImg++) {
        header = _dyld_get_image_header(iImg);
        if (header != NULL) {
            // Look for a segment command with this address within its range.
            uintptr_t addressWSlide = address - (uintptr_t)_dyld_get_image_vmaddr_slide(iImg);
            uintptr_t cmdPtr = bs_firstCmdAfterHeader(header);
            if (cmdPtr == 0) {
                continue;
            }
            for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
                const struct load_command *loadCmd = (struct load_command *)cmdPtr;
                if (loadCmd->cmd == LC_SEGMENT) {
                    const struct segment_command *segCmd = (struct segment_command *)cmdPtr;
                    if (addressWSlide >= segCmd->vmaddr &&
                        addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                } else if (loadCmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segCmd = (struct segment_command_64 *)cmdPtr;
                    if (addressWSlide >= segCmd->vmaddr &&
                        addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                }
                cmdPtr += loadCmd->cmdsize;
            }
        }
    }
    return UINT_MAX;
}

static uintptr_t bs_segmentBaseOfImageIndex(const uint32_t idx) {
    const struct mach_header *header = _dyld_get_image_header(idx);

    // Look for a segment command and return the file image address.
    uintptr_t cmdPtr = bs_firstCmdAfterHeader(header);
    if (cmdPtr == 0) {
        return 0;
    }
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *loadCmd = (struct load_command *)cmdPtr;
        if (loadCmd->cmd == LC_SEGMENT) {
            const struct segment_command *segmentCmd = (struct segment_command *)cmdPtr;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff;
            }
        } else if (loadCmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segmentCmd = (struct segment_command_64 *)cmdPtr;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return (uintptr_t)(segmentCmd->vmaddr - segmentCmd->fileoff);
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return 0;
}
