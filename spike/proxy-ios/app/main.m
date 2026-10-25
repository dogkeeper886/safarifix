#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <signal.h>

#import "Proxy.h"

// The proxy test app: runs Proxy on 127.0.0.1:8118 and keeps itself running in the background with a silent
// audio loop, so Safari can use it while Safari is in front. Every 30 seconds it logs a heartbeat to the phone's
// log, prefixed "proxy-test:", for tools/phone/log.sh; a gap in the heartbeats means iOS suspended the app.

static const uint16_t kPort = 8118;

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

static unsigned long ResidentMegabytes(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (unsigned long)(info.resident_size / (1024 * 1024));
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    Proxy *_proxy;
    AVAudioPlayer *_silence;
    dispatch_source_t _heartbeat;
    CFTimeInterval _started;
    UITextView *_text;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [UIViewController new];
    _text = [[UITextView alloc] initWithFrame:CGRectInset(root.view.bounds, 8, 24)];
    _text.editable = NO;
    _text.font = [UIFont fontWithName:@"Menlo" size:11];
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_text];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];

    _started = CACurrentMediaTime();
    _proxy = [[Proxy alloc] initWithPort:kPort];
    BOOL listening = [_proxy start];
    [self log:listening ? @"listening on 127.0.0.1:8118" : @"FAILED to open 127.0.0.1:8118"];
    [self log:@"Set Wi-Fi → (i) → HTTP Proxy → Auto, URL http://127.0.0.1:8118/proxy.pac"];
    [self startSilence];

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
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [self log:@"terminating"];
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
    BOOL playing = [_silence play];
    [self log:playing ? @"silence playing" : [NSString stringWithFormat:@"silence FAILED: %@", error.localizedDescription]];
}

- (void)beat {
    UIApplication *app = [UIApplication sharedApplication];
    NSString *state = @[@"active", @"inactive", @"background"][app.applicationState];
    NSTimeInterval left = app.backgroundTimeRemaining;
    NSString *time = left > 1e9 ? @"unlimited" : [NSString stringWithFormat:@"%.0f s", left];
    [self log:[NSString stringWithFormat:@"up %.0f s, %@, background time %@, audio %@, %@, %lu MB",
               CACurrentMediaTime() - _started, state, time, _silence.playing ? @"on" : @"OFF",
               [_proxy stats], ResidentMegabytes()]];
}

- (void)log:(NSString *)line {
    NSLog(@"proxy-test: %@", line);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_text.text = [self->_text.text stringByAppendingFormat:@"%@\n", line];
    });
}

@end

int main(int argc, char *argv[]) {
    // A peer that closes mid-send must fail the send, not kill the app.
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
