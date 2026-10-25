#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/time.h>

#import "SFDebugLog.h"

// Lines kept in memory and in log.txt.
static const NSUInteger kKeep = 3000;
// Lines on the Details screen.
static const NSUInteger kShow = 300;

typedef struct {
    long requests, failed, cancelled, console, errors;
    long long bytes;
} Counts;

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
// Everything below is read and written under gLock.
static NSMutableArray<NSString *> *gLines;
static BOOL gDirty;
static Counts gRun, gPage;
static long gPages;
static NSString *gPageURL;
static CFAbsoluteTime gStarted, gPageStarted;
static BOOL gPageDone;
// The latest memory sample, the peak, and memory warnings.
static unsigned long long gMapped, gPeak, gGap, gTop, gFootprint;
static long gWarnings;
static NSString *gCoreStatus = @"", *gCoreLog = @"", *gPreviousTail = @"";
// The last script errors the page watcher reported, which WebKit then reports again.
static NSMutableArray<NSString *> *gWatchedErrors;

static NSString *gFolder;
static dispatch_queue_t gQueue;
static dispatch_source_t gMemoryTimer, gFlushTimer;
static NSString *(^gCoreStatusBlock)(void), *(^gCoreLogBlock)(void);

static NSString *Now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000)];
}

static void Add(NSString *kind, NSString *text) {
    NSString *line = [NSString stringWithFormat:@"%@ %-7s %@", Now(), kind.UTF8String, text];
    pthread_mutex_lock(&gLock);
    if (!gLines) gLines = [NSMutableArray array];
    [gLines addObject:line];
    if (gLines.count > kKeep + 500) [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - kKeep)];
    gDirty = YES;
    pthread_mutex_unlock(&gLock);
}

static NSString *Bytes(long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0];
}

static NSString *Clip(NSString *s, NSUInteger max) {
    s = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    return s.length > max ? [[s substringToIndex:max - 1] stringByAppendingString:@"…"] : s;
}

NSString *SFDebugShortURL(NSURL *url) {
    if (!url) return @"-";
    NSString *where = url.host ?: url.scheme ?: @"";
    NSString *path = CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)url));
    NSString *s = Clip([where stringByAppendingString:path.length ? path : @"/"], 120);
    return url.query.length ? [s stringByAppendingString:@"?…"] : s;
}

void SFDebugApp(NSString *line) {
    NSLog(@"SafariFix: %@", line);
    Add(@"app", line);
}

void SFDebugPageStarted(NSURL *url) {
    NSString *page = SFDebugShortURL(url);
    pthread_mutex_lock(&gLock);
    gPage = (Counts){0};
    gPageURL = page;
    gPageStarted = CFAbsoluteTimeGetCurrent();
    gPageDone = NO;
    gPages++;
    pthread_mutex_unlock(&gLock);
    Add(@"page", [@"open " stringByAppendingString:page]);
}

void SFDebugPageFinished(NSURL *url) {
    NSString *page = url ? SFDebugShortURL(url) : nil;
    pthread_mutex_lock(&gLock);
    if (!gPageURL || gPageDone) {
        pthread_mutex_unlock(&gLock);
        return;
    }
    gPageDone = YES;
    // Messages name their frame when it isn't this page, so the page's address after redirects.
    if (page) gPageURL = page;
    Counts c = gPage;
    NSString *line = [NSString stringWithFormat:@"done %@ in %.1f s: %ld requests, %ld failed, %ld cancelled, %@; "
                                                 @"console %ld, %ld errors",
                                                gPageURL, CFAbsoluteTimeGetCurrent() - gPageStarted, c.requests, c.failed,
                                                c.cancelled, Bytes(c.bytes), c.console, c.errors];
    pthread_mutex_unlock(&gLock);
    NSLog(@"SafariFix: %@", line);
    Add(@"page", line);
}

void SFDebugPageFailed(NSError *error) {
    pthread_mutex_lock(&gLock);
    NSString *page = gPageURL ?: @"-";
    gPageDone = YES;
    pthread_mutex_unlock(&gLock);
    NSString *line = [NSString stringWithFormat:@"FAILED %@: %@ %ld %@", page, error.domain, (long)error.code,
                                                Clip(error.localizedDescription ?: @"", 160)];
    NSLog(@"SafariFix: %@", line);
    Add(@"page", line);
}

void SFDebugRequest(NSString *method, NSURL *url, NSInteger status, NSString *type, long long bytes, double seconds,
                    NSError *error, BOOL cancelled, NSURL *redirect) {
    BOOL failed = !cancelled && error;
    pthread_mutex_lock(&gLock);
    gRun.requests++, gPage.requests++;
    gRun.bytes += bytes, gPage.bytes += bytes;
    if (failed) gRun.failed++, gPage.failed++;
    if (cancelled) gRun.cancelled++, gPage.cancelled++;
    pthread_mutex_unlock(&gLock);

    NSString *what;
    if (cancelled) {
        what = @"cancelled by the page";
    } else if (error) {
        what = [NSString stringWithFormat:@"FAILED %@ %ld %@", error.domain, (long)error.code,
                                          Clip(error.localizedDescription ?: @"", 120)];
    } else if (redirect) {
        what = [NSString stringWithFormat:@"%ld → %@", (long)status, SFDebugShortURL(redirect)];
    } else {
        what = [NSString stringWithFormat:@"%ld %@ %@", (long)status, type ?: @"-", Bytes(bytes)];
    }
    Add(@"request", [NSString stringWithFormat:@"%@ %@ %.2f s %@", method, SFDebugShortURL(url), seconds, what]);
}

void SFDebugConsole(NSDictionary *message) {
    if (![message isKindOfClass:[NSDictionary class]]) return;
    NSString *text = message[@"message"];
    if (![text isKindOfClass:[NSString class]]) {
        Add(@"console", [@"(a message without text; keys " stringByAppendingFormat:@"%@)",
                         [message.allKeys componentsJoinedByString:@", "]]);
        return;
    }
    // WebKit names them like ErrorMessageLevel and JSMessageSource.
    NSString *level = [message[@"MessageLevel"] description] ?: @"?";
    NSString *source = [message[@"MessageSource"] description] ?: @"?";
    level = [[level stringByReplacingOccurrencesOfString:@"MessageLevel" withString:@""] lowercaseString];
    source = [[source stringByReplacingOccurrencesOfString:@"MessageSource" withString:@""] lowercaseString];
    BOOL webkit = [message[@"webkit"] boolValue];
    BOOL js = [source isEqualToString:@"js"];
    // WebKit reports each console call again, after the page watcher, which has its frame and its arguments in full.
    if (webkit && [source isEqualToString:@"consoleapi"]) return;
    BOOL error = [level isEqualToString:@"error"];
    // The frame it came from, when that isn't the page: an ad's frame, or the last page, still running as the next
    // one opens.
    NSString *from = @"";
    NSString *frame = message[@"frame"];
    NSRange space = [frame isKindOfClass:[NSString class]] ? [frame rangeOfString:@" "] : NSMakeRange(NSNotFound, 0);
    NSString *frameURL = space.location == NSNotFound
                             ? nil
                             : SFDebugShortURL([NSURL URLWithString:[frame substringFromIndex:NSMaxRange(space)]]);
    pthread_mutex_lock(&gLock);
    // It also reports each script error the watcher saw, just after it. WebKit alone reports the rest: a frame
    // blocked from another site's, or the text of another site's script error, which the page sees as "Script error.".
    if (js) {
        if (!gWatchedErrors) gWatchedErrors = [NSMutableArray array];
        NSUInteger seen = webkit ? [gWatchedErrors indexOfObject:text] : NSNotFound;
        if (seen != NSNotFound) {
            [gWatchedErrors removeObjectAtIndex:seen];
            pthread_mutex_unlock(&gLock);
            return;
        }
        if (!webkit) {
            [gWatchedErrors addObject:text];
            if (gWatchedErrors.count > 20) [gWatchedErrors removeObjectAtIndex:0];
        }
    }
    gRun.console++, gPage.console++;
    if (error) gRun.errors++, gPage.errors++;
    if (frameURL && ![frameURL isEqualToString:gPageURL ?: @""])
        from = [NSString stringWithFormat:@" from %@ %@", [frame substringToIndex:space.location], frameURL];
    pthread_mutex_unlock(&gLock);

    NSString *where = @"";
    NSString *url = message[@"sourceURL"];
    if ([url isKindOfClass:[NSString class]] && url.length) {
        where = [NSString stringWithFormat:@" at %@:%@:%@", SFDebugShortURL([NSURL URLWithString:url]),
                                           message[@"lineNumber"] ?: @"?", message[@"columnNumber"] ?: @"?"];
    }
    Add(webkit ? @"webkit" : @"console",
        [NSString stringWithFormat:@"%@ %@: %@%@%@", level, source, Clip(text, 300), where, from]);
}

/// The app's address space: how much is mapped, the largest free gap, between mappings or past the highest, and
/// where the highest ends. A 32-bit app has 2 GB of it; WebKit fails, and stops the app, when it can't map 4 MB more.
static void SampleMemory(void) {
    vm_address_t address = 0, end = 0;
    unsigned long long mapped = 0, gap = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) !=
            KERN_SUCCESS)
            break;
        if (end && address > end && address - end > gap) gap = address - end;
        mapped += size;
        end = address + size;
        if (end < address) break;
        address = end;
    }
    // Past the highest mapping, the rest of the 2 GB is free too.
    if (end < 0x80000000u && 0x80000000u - end > gap) gap = 0x80000000u - end;
    // The memory the system counts against the app's limit.
    unsigned long long footprint = 0;
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) footprint = vm.phys_footprint;

    static unsigned long long logged;
    static CFAbsoluteTime loggedAt;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    pthread_mutex_lock(&gLock);
    gMapped = mapped, gGap = gap, gTop = end, gFootprint = footprint;
    if (mapped > gPeak) gPeak = mapped;
    pthread_mutex_unlock(&gLock);
    // A line when it moved 16 MB, or once a minute.
    if (llabs((long long)mapped - (long long)logged) >= 16 << 20 || now - loggedAt >= 60) {
        logged = mapped, loggedAt = now;
        Add(@"memory", [NSString stringWithFormat:@"%llu MB mapped, largest gap %llu MB, top 0x%08lx, footprint %llu MB",
                                                  mapped >> 20, gap >> 20, (unsigned long)end, footprint >> 20]);
    }
}

static NSString *Summary(void) {
    pthread_mutex_lock(&gLock);
    NSString *s = [NSString stringWithFormat:
        @"Up %.0f min, %ld pages, now %@\n"
        @"Requests %ld: %ld failed, %ld cancelled by pages, %@\n"
        @"Console %ld messages, %ld errors\n"
        @"Memory %llu MB of the 2048 MB address space (peak %llu MB), largest gap %llu MB, footprint %llu MB, "
        @"%ld memory warnings\n"
        @"Core %@\n",
        (CFAbsoluteTimeGetCurrent() - gStarted) / 60, gPages, gPageURL ?: @"-", gRun.requests, gRun.failed,
        gRun.cancelled, Bytes(gRun.bytes), gRun.console, gRun.errors, gMapped >> 20, gPeak >> 20, gGap >> 20,
        gFootprint >> 20, gWarnings, gCoreStatus];
    pthread_mutex_unlock(&gLock);
    return s;
}

static void Write(NSString *text, NSString *name) {
    [[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[gFolder stringByAppendingPathComponent:name]
                                                    atomically:YES];
}

/// Writes the files the core serves, each only when it changed, since the app runs all day; runs on gQueue.
static void Flush(void) {
    static NSString *writtenSummary, *writtenCoreLog;
    NSString *status = gCoreStatusBlock ? gCoreStatusBlock() : @"";
    NSString *coreLog = (gCoreLogBlock ? gCoreLogBlock() : nil) ?: @"";
    pthread_mutex_lock(&gLock);
    gCoreStatus = status ?: @"", gCoreLog = coreLog;
    NSString *log = gDirty ? [[gLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : nil;
    gDirty = NO;
    pthread_mutex_unlock(&gLock);
    if (log) Write(log, @"log.txt");
    NSString *summary = Summary();
    if (![summary isEqualToString:writtenSummary]) Write(writtenSummary = summary, @"summary.txt");
    if (![coreLog isEqualToString:writtenCoreLog]) Write(writtenCoreLog = coreLog, @"core.txt");
}

static dispatch_source_t Every(double seconds, dispatch_block_t block) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              (uint64_t)(seconds * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
    return timer;
}

void SFDebugStart(NSString *folder, NSString *(^coreStatus)(void), NSString *(^coreLog)(void)) {
    gFolder = folder;
    gCoreStatusBlock = [coreStatus copy];
    gCoreLogBlock = [coreLog copy];
    gStarted = CFAbsoluteTimeGetCurrent();
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *last = [folder stringByAppendingPathComponent:@"log.txt"];
    NSString *previous = [folder stringByAppendingPathComponent:@"previous.txt"];
    if ([files fileExistsAtPath:last]) {
        [files removeItemAtPath:previous error:nil];
        [files moveItemAtPath:last toPath:previous error:nil];
    }
    NSArray *lines = [[NSString stringWithContentsOfFile:previous encoding:NSUTF8StringEncoding error:nil]
        componentsSeparatedByString:@"\n"];
    if (lines.count > 41) lines = [lines subarrayWithRange:NSMakeRange(lines.count - 41, 41)];
    gPreviousTail = [lines componentsJoinedByString:@"\n"] ?: @"";

    gQueue = dispatch_queue_create("debug log", DISPATCH_QUEUE_SERIAL);

    gMemoryTimer = Every(5, ^{ SampleMemory(); });
    gFlushTimer = Every(2, ^{ Flush(); });
    dispatch_async(gQueue, ^{ SampleMemory(); });

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
                        pthread_mutex_lock(&gLock);
                        gWarnings++;
                        pthread_mutex_unlock(&gLock);
                        SFDebugApp(@"memory warning");
                    }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
                        Add(@"app", @"in the background");
                        dispatch_async(gQueue, ^{ Flush(); });
                    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) { Add(@"app", @"in front"); }];
}

NSString *SFDebugDetails(void) {
    pthread_mutex_lock(&gLock);
    NSUInteger from = gLines.count > kShow ? gLines.count - kShow : 0;
    NSString *timeline = [[gLines subarrayWithRange:NSMakeRange(from, gLines.count - from)] componentsJoinedByString:@"\n"];
    NSString *core = gCoreLog, *previous = gPreviousTail;
    pthread_mutex_unlock(&gLock);
    return [NSString stringWithFormat:@"%@\n— Timeline, last %lu lines —\n%@\n\n— The previous run's last lines —\n%@\n\n"
                                      @"— Core —\n%@",
                                      Summary(), (unsigned long)kShow, timeline ?: @"", previous.length ? previous : @"none",
                                      core];
}
