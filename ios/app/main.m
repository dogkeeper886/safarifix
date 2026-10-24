#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>

#include "libsafarifix.h"

// SafariFix's app: runs the core's proxy on 127.0.0.1:8118 for Safari, and keeps itself running in the background
// with a silent audio loop, so the proxy serves Safari while Safari is in front. Every 30 seconds it logs a
// heartbeat to the phone's log, prefixed "SafariFix:"; a gap in the heartbeats means iOS suspended the app.

static const int kPort = 8118;
static NSString *const kSetupURL = @"http://127.0.0.1:8118/";

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

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    AVAudioPlayer *_silence;
    dispatch_source_t _heartbeat;
    UILabel *_status;
    UIButton *_setup;
    UITextView *_help;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor whiteColor];
    [self buildScreenIn:root.view];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];

    [self startSilence];
    [self showStatus:@"Starting… The first start makes your root certificate, which takes a while."];
    NSString *data = [self folder:NSApplicationSupportDirectory named:@"SafariFix"];
    NSString *cache = [self folder:NSCachesDirectory named:@"scripts"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = TakeString(SFStart((char *)data.UTF8String, (char *)cache.UTF8String, kPort));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self log:error ? [@"FAILED to start: " stringByAppendingString:error] : @"started"];
            self->_setup.enabled = error == nil;
            [self refresh];
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

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self log:@"entered the background"];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [self log:@"entering the foreground"];
    [self refresh];
}

- (void)buildScreenIn:(UIView *)view {
    CGFloat width = view.bounds.size.width - 32;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 28, width, 30)];
    title.text = @"SafariFix";
    title.font = [UIFont boldSystemFontOfSize:24];
    [view addSubview:title];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 62, width, 64)];
    _status.numberOfLines = 0;
    _status.font = [UIFont systemFontOfSize:13];
    [view addSubview:_status];

    // Enabled once the proxy listens; Safari finds nothing on 127.0.0.1:8118 before that.
    _setup = [UIButton buttonWithType:UIButtonTypeSystem];
    _setup.frame = CGRectMake(16, 130, width, 36);
    _setup.enabled = NO;
    [_setup setTitle:@"Open the setup page in Safari" forState:UIControlStateNormal];
    _setup.titleLabel.font = [UIFont systemFontOfSize:17];
    [_setup addTarget:self action:@selector(openSetup) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:_setup];

    _help = [[UITextView alloc] initWithFrame:CGRectMake(12, 172, width + 8, view.bounds.size.height - 180)];
    _help.editable = NO;
    _help.font = [UIFont systemFontOfSize:14];
    _help.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _help.text = @"Set up once:\n"
        "1. Settings → Wi-Fi → (i) next to your network → HTTP Proxy → Auto, URL http://127.0.0.1:8118/proxy.pac\n"
        "2. Open the setup page in Safari, tap “Install the root certificate”, then Allow and Install.\n"
        "3. Settings → General → About → Certificate Trust Settings: turn on the SafariFix root named above, "
        "and tap Continue on the warning. Until its switch is on, Safari can't open any fixed site.\n\n"
        "Then keep SafariFix running in the background: it plays silence to stay awake. "
        "In the app switcher, swipe away only Safari, never SafariFix. "
        "While it isn't running, Safari goes straight to the internet, unfixed.";
    [view addSubview:_help];
}

- (void)openSetup {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:kSetupURL] options:@{} completionHandler:nil];
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

- (void)refresh {
    NSString *rootName = TakeString(SFRootName());
    NSString *status = TakeString(SFStatus());
    [self showStatus:rootName.length ? [NSString stringWithFormat:@"Running on 127.0.0.1:%d. Root certificate: %@.\n%@", kPort, rootName, status]
                                     : status];
}

- (void)showStatus:(NSString *)text {
    _status.text = text;
}

- (void)beat {
    UIApplication *app = [UIApplication sharedApplication];
    NSString *state = @[@"active", @"inactive", @"background"][app.applicationState];
    NSTimeInterval left = app.backgroundTimeRemaining;
    NSString *time = left > 1e9 ? @"unlimited" : [NSString stringWithFormat:@"%.0f s", left];
    [self log:[NSString stringWithFormat:@"%@, background time %@, audio %@; %@", state, time,
               _silence.playing ? @"on" : @"OFF", TakeString(SFStatus())]];
    if (app.applicationState == UIApplicationStateActive) [self refresh];
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
