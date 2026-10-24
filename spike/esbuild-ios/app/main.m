#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include "libesbuild.h"

// The build test app: rewrites each bundled sample script with esbuild three times and shows how long each run
// took. Each line also goes to the phone's log, prefixed "esbuild-test:", for tools/inspect.sh log.
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    UITextView *_text;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [UIViewController new];
    _text = [[UITextView alloc] initWithFrame:root.view.bounds];
    _text.editable = NO;
    _text.font = [UIFont fontWithName:@"Menlo" size:11];
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_text];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runSamples];
    });
    return YES;
}

- (void)report:(NSString *)line {
    NSLog(@"esbuild-test: %@", line);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_text.text = [self->_text.text stringByAppendingFormat:@"%@\n", line];
    });
}

- (void)runSamples {
    NSArray<NSString *> *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"js" inDirectory:@"samples"];
    [self report:[NSString stringWithFormat:@"%lu samples", (unsigned long)paths.count]];
    for (NSString *path in paths) {
        NSData *code = [NSData dataWithContentsOfFile:path];
        // The first run includes warming up; the later runs show the steady speed.
        for (int run = 1; run <= 3; run++) {
            int outLen = 0;
            char *err = NULL;
            CFTimeInterval start = CACurrentMediaTime();
            char *out = SFTransform((char *)code.bytes, (int)code.length, &outLen, &err);
            double ms = (CACurrentMediaTime() - start) * 1000;
            if (err) {
                [self report:[NSString stringWithFormat:@"%@ run %d FAILED in %.0f ms: %s", path.lastPathComponent, run, ms, err]];
                free(err);
                break;
            }
            [self report:[NSString stringWithFormat:@"%@ run %d: %lu -> %d B in %.0f ms",
                          path.lastPathComponent, run, (unsigned long)code.length, outLen, ms]];
            free(out);
        }
    }
    [self report:@"done"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
