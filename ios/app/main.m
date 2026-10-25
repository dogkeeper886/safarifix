#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>

#include "libsafarifix.h"
#import "SFChecks.h"
#import "SFDetailsViewController.h"
#import "SFMainView.h"

// SafariFix's app: runs the core's proxy on 127.0.0.1:8118 for Safari, and keeps itself running in the background
// with a silent audio loop, so the proxy serves Safari while Safari is in front.
// The main screen (SFMainView) shows only what the user needs: whether Safari is ready, the setup steps left, and
// when the signing runs out. Everything for debugging goes to the phone's log, prefixed "SafariFix:", and to the
// Details screen: every 30 seconds a heartbeat, where a gap means iOS suspended the app, and each change the
// setup checks find. A debug build (DEBUG=1 ios/build.sh) also saves pictures of the main screen, which the proxy
// serves on http://127.0.0.1:8118/debug/.

static const int kPort = 8118;
static NSString *const kSetupURL = @"http://127.0.0.1:8118/";
static NSString *const kPACURL = @"http://127.0.0.1:8118/proxy.pac";

/// One second of 16-bit mono silence at 8 kHz, as a WAV file.
static NSData *SilentWav(void) {
    const uint32_t rate = 8000, dataSize = rate * 2;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + dataSize];
    uint8_t *p = wav.mutableBytes;
    uint32_t u32;
    uint16_t u16;
    memcpy(p, "RIFF", 4);
    u32 = 36 + dataSize; memcpy(p + 4, &u32, 4);
    memcpy(p + 8, "WAVEfmt ", 8);
    u32 = 16; memcpy(p + 16, &u32, 4);
    u16 = 1; memcpy(p + 20, &u16, 2);         // PCM
    u16 = 1; memcpy(p + 22, &u16, 2);         // mono
    u32 = rate; memcpy(p + 24, &u32, 4);
    u32 = rate * 2; memcpy(p + 28, &u32, 4);  // bytes per second
    u16 = 2; memcpy(p + 32, &u16, 2);         // bytes per frame
    u16 = 16; memcpy(p + 34, &u16, 2);        // bits per sample
    memcpy(p + 36, "data", 4);
    u32 = dataSize; memcpy(p + 40, &u32, 4);
    return wav;
}

/// Returns a C string from the core as an NSString, and frees it.
static NSString *TakeString(char *s) {
    if (!s) return nil;
    NSString *string = [NSString stringWithUTF8String:s];
    free(s);
    return string;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate, SFMainViewActions>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    AVAudioPlayer *_silence;
    dispatch_source_t _heartbeat;
    // Runs the setup checks every 2 seconds while the app is in front, so the screen follows the user's changes.
    NSTimer *_checks;
    BOOL _checkingTrust;
    SFMainView *_main;
    SFModel *_model;
    // What the checks found, for the Details screen and the log.
    NSString *_proxyFound, *_trustFound, *_lastSetup;
    // Where a debug build saves its pictures; empty otherwise.
    NSString *_debugDir;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    _model = [SFModel new];
    _model.core = SFCoreStarting;
    _model.pacURL = kPACURL;
    _model.signedUntil = SFSignedUntil();
    [self log:[NSString stringWithFormat:@"signed until %@", _model.signedUntil ?: @"unknown"]];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [UIViewController new];
    root.automaticallyAdjustsScrollViewInsets = NO;
    _main = [[SFMainView alloc] initWithFrame:self.window.bounds];
    _main.actions = self;
    root.view = _main;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    [self show];

    [self startSilence];
    NSString *data = [self folder:NSApplicationSupportDirectory named:@"SafariFix"];
    NSString *cache = [self folder:NSCachesDirectory named:@"scripts"];
#if SF_DEBUG
    _debugDir = [self folder:NSCachesDirectory named:@"debug"];
#else
    _debugDir = @"";
#endif
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SFSetTimeZone((int)[NSTimeZone localTimeZone].secondsFromGMT);
        NSString *error = TakeString(SFStart((char *)data.UTF8String, (char *)cache.UTF8String,
                                             (char *)self->_debugDir.UTF8String, kPort));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:error ? [@"FAILED to start: " stringByAppendingString:error] : @"started"];
            self->_model.core = error ? SFCoreFailed : SFCoreRunning;
            self->_model.failure = error;
            self->_model.rootName = TakeString(SFRootName());
            [self check];
#if SF_DEBUG
            [self saveStates];
#endif
        });
    });

    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_heartbeat, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(_heartbeat, ^{ [self beat]; });
    dispatch_resume(_heartbeat);

    // Calls and other apps' audio can interrupt the session; start the silence again when they end.
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        [self log:type == AVAudioSessionInterruptionTypeBegan ? @"audio interrupted" : @"audio interruption ended"];
        if (type == AVAudioSessionInterruptionTypeEnded) [self startSilence];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
        [self log:@"media services reset"];
        self->_silence = nil;
        [self startSilence];
    }];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self check];
    _checks = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(check) userInfo:nil repeats:YES];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [_checks invalidate];
    _checks = nil;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self log:@"entered the background"];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [self log:@"entering the foreground"];
}

/// Checks the proxy setting at once and the root's trust off the main thread, then shows what they found.
- (void)check {
    if (_model.core != SFCoreRunning) return;
    NSString *found = nil;
    _model.proxySet = SFCheckProxy(kPort, &found);
    _proxyFound = found;
    if (!_checkingTrust) {
        _checkingTrust = YES;
        NSString *chain = TakeString(SFTestChain());
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *trustFound = nil;
            SFCheck trusted = SFCheckTrust(chain, &trustFound);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_checkingTrust = NO;
                self->_model.trusted = trusted;
                self->_trustFound = trustFound;
                [self show];
            });
        });
    }
    [self show];
}

- (void)show {
    [_main show:_model];
    NSString *setup = [NSString stringWithFormat:@"Wi-Fi proxy %@; certificate %@", _proxyFound ?: @"not checked",
                       _trustFound ?: @"not checked"];
    if (![setup isEqualToString:_lastSetup]) {
        _lastSetup = setup;
        [self log:[@"setup: " stringByAppendingString:setup]];
    }
#if SF_DEBUG
    [self saveScreen];
#endif
}

// SFMainViewActions

- (void)installCertificate {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kSetupURL] options:@{} completionHandler:nil];
}

- (void)copyPACURL {
    [UIPasteboard generalPasteboard].string = kPACURL;
    [_main showCopied];
}

- (void)showDetails {
    __weak AppDelegate *weakSelf = self;
    SFDetailsViewController *details = [[SFDetailsViewController alloc] initWithText:^{ return [weakSelf details]; }];
    [self.window.rootViewController presentViewController:[[UINavigationController alloc] initWithRootViewController:details]
                                                 animated:YES completion:nil];
}

/// The Details screen's text.
- (NSString *)details {
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *core = @[@"starting", @"running", @"FAILED: "][_model.core];
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"Core          %@%@ on 127.0.0.1:%d\n", core, _model.failure ?: @"", kPort];
    [text appendFormat:@"PAC file      %@\n", kPACURL];
    [text appendFormat:@"Wi-Fi proxy   %@\n", _proxyFound ?: @"not checked"];
    [text appendFormat:@"Root          %@\n", _model.rootName.length ? _model.rootName : @"none yet"];
    [text appendFormat:@"Certificate   %@\n", _trustFound ?: @"not checked"];
    [text appendFormat:@"Signed until  %@\n",
     _model.signedUntil ? [format stringFromDate:_model.signedUntil] : @"unknown: no embedded profile"];
    [text appendFormat:@"App           %@\n", [self appState]];
    [text appendFormat:@"Version       %@ (%@)%@\n", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
     _debugDir.length ? @", debug build" : @""];
    [text appendFormat:@"\nCounts\n%@\n", TakeString(SFStatus())];
    [text appendFormat:@"\nThe core's last log lines\n%@\n", TakeString(SFRecentLog())];
    return text;
}

/// Plays a looping silence, mixed with other apps' audio, which the audio background mode keeps running.
- (void)startSilence {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error]
        || ![session setActive:YES error:&error]) {
        [self log:[NSString stringWithFormat:@"audio session FAILED: %@", error.localizedDescription]];
        return;
    }
    if (!_silence) {
        _silence = [[AVAudioPlayer alloc] initWithData:SilentWav() error:&error];
        _silence.numberOfLoops = -1;
    }
    if (![_silence play]) [self log:[NSString stringWithFormat:@"silence FAILED: %@", error.localizedDescription]];
}

- (NSString *)appState {
    UIApplication *app = [UIApplication sharedApplication];
    NSString *state = @[@"active", @"inactive", @"background"][app.applicationState];
    NSTimeInterval left = app.backgroundTimeRemaining;
    NSString *time = left > 1e9 ? @"unlimited" : [NSString stringWithFormat:@"%.0f s", left];
    return [NSString stringWithFormat:@"%@, background time %@, audio %@", state, time, _silence.playing ? @"on" : @"OFF"];
}

- (void)beat {
    [self log:[NSString stringWithFormat:@"%@; %@", [self appState], TakeString(SFStatus())]];
}

- (NSString *)folder:(NSSearchPathDirectory)directory named:(NSString *)name {
    NSString *path = [NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

- (void)log:(NSString *)line {
    NSLog(@"SafariFix: %@", line);
}

#if SF_DEBUG
static NSData *PNGOf(UIView *view) {
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, 0);
    [view.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(image);
}

/// Saves the screen as it is to debug/screen.png, once its layout is done.
- (void)saveScreen {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        [self.window layoutIfNeeded];
        [PNGOf(self.window) writeToFile:[self->_debugDir stringByAppendingPathComponent:@"screen.png"] atomically:YES];
    });
}

/// Saves the main screen in each state to debug/state-<name>.png, to check the design from the PC without
/// changing the phone's settings.
- (void)saveStates {
    NSDictionary<NSString *, SFModel *> *states = @{
        @"starting": [self sample:SFCoreStarting trusted:SFCheckUnknown proxy:SFCheckUnknown],
        @"failed": [self sample:SFCoreFailed trusted:SFCheckUnknown proxy:SFCheckUnknown],
        @"checking": [self sample:SFCoreRunning trusted:SFCheckUnknown proxy:SFCheckNo],
        @"setup": [self sample:SFCoreRunning trusted:SFCheckNo proxy:SFCheckNo],
        @"setup-step2": [self sample:SFCoreRunning trusted:SFCheckYes proxy:SFCheckNo],
        @"untrusted": [self sample:SFCoreRunning trusted:SFCheckNo proxy:SFCheckYes],
        @"ready": [self sample:SFCoreRunning trusted:SFCheckYes proxy:SFCheckYes],
    };
    for (NSString *name in states) {
        SFMainView *view = [[SFMainView alloc] initWithFrame:self.window.bounds];
        [view show:states[name]];
        [view layoutIfNeeded];
        [PNGOf(view) writeToFile:[_debugDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"state-%@.png", name]] atomically:YES];
    }
    SFModel *soon = [self sample:SFCoreRunning trusted:SFCheckYes proxy:SFCheckYes];
    soon.signedUntil = [NSDate dateWithTimeIntervalSinceNow:24 * 3600];
    SFMainView *view = [[SFMainView alloc] initWithFrame:self.window.bounds];
    [view show:soon];
    [view layoutIfNeeded];
    [PNGOf(view) writeToFile:[_debugDir stringByAppendingPathComponent:@"state-renew-soon.png"] atomically:YES];
    [self log:@"saved the main screen's states in debug/"];
}

- (SFModel *)sample:(SFCore)core trusted:(SFCheck)trusted proxy:(SFCheck)proxy {
    SFModel *model = [SFModel new];
    model.core = core;
    model.failure = @"listen tcp 127.0.0.1:8118: bind: address already in use";
    model.rootName = _model.rootName.length ? _model.rootName : @"SafariFix root 000000";
    model.trusted = trusted;
    model.proxySet = proxy;
    model.pacURL = kPACURL;
    model.signedUntil = _model.signedUntil ?: [NSDate dateWithTimeIntervalSinceNow:5 * 24 * 3600];
    return model;
}
#endif

@end

/// Sends stderr to a file, after logging what the last run left there: when Go's runtime dies it writes why to
/// stderr and aborts at once, and iOS keeps no stderr.
static void KeepStderr(void) {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"stderr.txt"];
    NSString *last = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [last componentsSeparatedByString:@"\n"]) {
        if (line.length) NSLog(@"SafariFix: last run's stderr: %@", line);
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        dup2(fd, STDERR_FILENO);
        close(fd);
    }
}

int main(int argc, char *argv[]) {
    // A peer that closes mid-send must fail the send, not kill the app.
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        KeepStderr();
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
