#import <Security/Security.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>

#import "DebugLog.h"
#import "SFDetailsViewController.h"
#include "libsafarifix.h"

// The browser test: a bare browser in a UIWebView that sends every request through the SafariFix core, running in
// the app. An NSURLProtocol hands each of the web view's requests to an NSURLSession that uses the core as its proxy
// and trusts the core's root, so neither a Wi-Fi proxy setting nor a trusted certificate is needed. Each page's
// requests, script errors and WebKit's messages go to the debug record (DebugLog.h), which the Debug button shows and
// the core serves under /debug/; the app's lines and each page's load time also go to the phone's log, prefixed
// "browser-test:". UIWebView, unlike WKWebView, loads in the app's own process, which is what lets the protocol see
// its requests; the price is JavaScript without the JIT.

// Not SafariFix's 8118, so both apps can run.
static const int kPort = 8128;
// Safari's on iOS 10.3.4, read from the phone, so sites treat the test browser as Safari.
static NSString *const kUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_4 like Mac OS X) AppleWebKit/603.3.8 "
                                     "(KHTML, like Gecko) Version/10.0 Mobile/14G61 Safari/602.1";
// Marks a request the protocol already passed on, so the session's own load doesn't come back to it.
static NSString *const kHandled = @"BrowserTestHandled";

static NSString *TakeString(char *s) {
    if (!s) return nil;
    NSString *string = [NSString stringWithUTF8String:s];
    free(s);
    return string;
}

/// The one thread that calls into the core. Go runs each call on a stack in its own heap, and the JavaScript collector,
/// scanning a thread it knows (the main thread, a queue thread that once ran JavaScript) mid-call, reads a stack size
/// past 2 GB and stops the app; this thread never runs JavaScript.
static NSThread *gCoreThread;

@interface CoreCall : NSObject
@end

@implementation CoreCall
+ (void)run:(dispatch_block_t)block {
    block();
}
@end

static void OnCore(BOOL wait, dispatch_block_t block) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCoreThread = [[NSThread alloc] initWithBlock:^{
            [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
            for (;;) [[NSRunLoop currentRunLoop] run];
        }];
        gCoreThread.name = @"core calls";
        [gCoreThread start];
    });
    [CoreCall performSelector:@selector(run:) onThread:gCoreThread withObject:[block copy] waitUntilDone:wait];
}

/// Reports a page's script errors, failed and blocked loads, and console calls to the debug record. It runs in each
/// frame as its JavaScript starts, before the page's own scripts, and takes the report function off the page.
static NSString *const kWatchScript = @
"(function () {\n"
"  var report = window.__browserTestReport;\n"
"  try { delete window.__browserTestReport; } catch (e) {}\n"
"  if (typeof report !== 'function') return;\n"
"  var where = (window === window.top ? 'page ' : 'frame ') + location.href;\n"
"  function text(a) {\n"
"    if (typeof a === 'string') return a;\n"
"    if (a instanceof Error) return String(a);\n"
"    try { var s = JSON.stringify(a); return s === undefined ? String(a) : s; } catch (e) { return String(a); }\n"
"  }\n"
"  window.addEventListener('error', function (e) {\n"
"    var t = e.target;\n"
"    if (t && t !== window && t.tagName) report('error', 'load', 'failed to load a ' + t.tagName.toLowerCase(), t.src || t.href || '', 0, 0, where);\n"
"    else report('error', 'js', String(e.message), e.filename || '', e.lineno || 0, e.colno || 0, where);\n"
"  }, true);\n"
"  window.addEventListener('unhandledrejection', function (e) { report('error', 'promise', 'unhandled rejection: ' + text(e.reason), '', 0, 0, where); });\n"
"  document.addEventListener('securitypolicyviolation', function (e) {\n"
"    report('error', 'security', 'blocked by the page\\'s policy ' + e.violatedDirective, e.blockedURI || '', 0, 0, where);\n"
"  }, true);\n"
"  ['error', 'warn', 'log', 'info', 'debug'].forEach(function (level) {\n"
"    var original = console[level];\n"
"    if (typeof original !== 'function') return;\n"
"    console[level] = function () {\n"
"      try { report(level, 'console', Array.prototype.map.call(arguments, text).join(' '), '', 0, 0, where); } catch (e) {}\n"
"      return original.apply(this, arguments);\n"
"    };\n"
"  });\n"
"})();";

/// WebKit's own messages, the rest of what the Web Inspector's console shows: failed and blocked loads, security
/// and CSS warnings. WebKit hands them to the UIWebView's browser view, once the web view allows messaging, which it
/// doesn't by default. Each goes to the debug record on its way.
static void (*gWebKitOriginal)(id, SEL, id, NSDictionary *, NSString *);

static void WebKitMessage(id self, SEL cmd, id webView, NSDictionary *message, NSString *source) {
    if ([message isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *tagged = [message mutableCopy];
        tagged[@"webkit"] = @YES;
        DebugConsole(tagged);
    }
    gWebKitOriginal(self, cmd, webView, message, source);
}

static void WatchWebKit(UIWebView *web) {
    SEL receive = NSSelectorFromString(@"webView:addMessageToConsole:withSource:");
    Method method = class_getInstanceMethod(NSClassFromString(@"UIWebBrowserView"), receive);
    id browser = [web respondsToSelector:NSSelectorFromString(@"_browserView")]
                     ? ((id (*)(id, SEL))objc_msgSend)(web, NSSelectorFromString(@"_browserView"))
                     : nil;
    id webView = [browser respondsToSelector:NSSelectorFromString(@"webView")]
                     ? ((id (*)(id, SEL))objc_msgSend)(browser, NSSelectorFromString(@"webView"))
                     : nil;
    SEL allow = NSSelectorFromString(@"_setAllowsMessaging:");
    if (!method || ![webView respondsToSelector:allow]) {
        DebugApp(@"WebKit's messages can't be watched on this iOS");
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWebKitOriginal = (void *)method_setImplementation(method, (IMP)WebKitMessage); });
    ((void (*)(id, SEL, BOOL))objc_msgSend)(webView, allow, YES);
}

@implementation NSObject (BrowserTestWatch)

// WebKit calls this on the web view's frame load delegate, on the thread that runs JavaScript, as each frame's
// JavaScript starts. UIKit's delegate doesn't have it, so this category answers. The context isn't kept: it would keep
// the page alive.
- (void)webView:(id)webView didCreateJavaScriptContext:(JSContext *)context forFrame:(id)frame {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ DebugApp(@"watching pages' scripts"); });
    context[@"__browserTestReport"] = ^(NSString *level, NSString *source, NSString *text, NSString *url, NSNumber *line,
                                        NSNumber *column, NSString *where) {
        DebugConsole(@{@"message": text ?: @"", @"MessageLevel": level ?: @"?", @"MessageSource": source ?: @"?",
                       @"sourceURL": url ?: @"", @"lineNumber": line ?: @0, @"columnNumber": column ?: @0,
                       @"frame": where ?: @""});
    };
    [context evaluateScript:kWatchScript];
}

@end

@class CoreProtocol;

/// The session every request goes out on, and which protocol instance each of its tasks serves.
static NSURLSession *gSession;
static NSMutableDictionary<NSNumber *, CoreProtocol *> *gLoads;
/// The core's root certificate, which signs the certificates the core shows for the sites it fixes.
static NSArray *gRoots;

@interface CoreProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, copy) NSArray<NSString *> *modes;
@property (atomic) BOOL redirected;
/// For the debug record; the session's delegate queue sets them.
@property (nonatomic) CFAbsoluteTime started;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSString *type;
@property (nonatomic) long long bytes;
/// Set once the web view stops the load, after which it takes no more callbacks; read on the client thread.
@property (nonatomic) BOOL stopped;
- (void)onClientThread:(dispatch_block_t)block;
@end

@implementation CoreProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
           ![self propertyForKey:kHandled inRequest:request];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // The web view expects its callbacks on the thread, and in the run loop mode, that started the load.
    self.thread = [NSThread currentThread];
    NSString *mode = [NSRunLoop currentRunLoop].currentMode;
    self.modes = mode && ![mode isEqualToString:NSDefaultRunLoopMode] ? @[NSDefaultRunLoopMode, mode] : @[NSDefaultRunLoopMode];
    NSMutableURLRequest *request = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:request];
    self.started = CFAbsoluteTimeGetCurrent();
    self.task = [gSession dataTaskWithRequest:request];
    @synchronized (gLoads) {
        gLoads[@(self.task.taskIdentifier)] = self;
    }
    [self.task resume];
}

- (void)stopLoading {
    self.stopped = YES;
    [self.task cancel];
}

- (void)onClientThread:(dispatch_block_t)block {
    [self performSelector:@selector(run:) onThread:self.thread withObject:[block copy] waitUntilDone:NO modes:self.modes];
}

- (void)run:(dispatch_block_t)block {
    if (!self.stopped) block();
}

@end

/// Passes the session's events to the protocol instance of each task.
@interface SessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation SessionDelegate

static CoreProtocol *LoadOf(NSURLSessionTask *task, BOOL remove) {
    @synchronized (gLoads) {
        CoreProtocol *load = gLoads[@(task.taskIdentifier)];
        if (remove) [gLoads removeObjectForKey:@(task.taskIdentifier)];
        return load;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    // The sites the core fixes show the core's certificates, and the ones it passes through show their own.
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)gRoots);
    SecTrustSetAnchorCertificatesOnly(trust, false);
    SecTrustResultType result = kSecTrustResultInvalid;
    if (SecTrustEvaluate(trust, &result) == errSecSuccess &&
        (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed)) {
        completion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        DebugApp([NSString stringWithFormat:@"untrusted certificate for %@ (%u)", challenge.protectionSpace.host,
                  (unsigned)result]);
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completion {
    // The web view follows redirects itself, so it shows the new URL and its request comes back through the protocol.
    CoreProtocol *load = LoadOf(task, NO);
    NSMutableURLRequest *next = [request mutableCopy];
    [NSURLProtocol removePropertyForKey:kHandled inRequest:next];
    load.redirected = YES;
    DebugRequest(load.request.HTTPMethod, load.request.URL, response.statusCode, nil, 0,
                 CFAbsoluteTimeGetCurrent() - load.started, nil, NO, request.URL);
    [load onClientThread:^{
        [load.client URLProtocol:load wasRedirectedToRequest:next redirectResponse:response];
        [load.client URLProtocol:load didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain
                                                                           code:NSUserCancelledError userInfo:nil]];
    }];
    completion(nil);
    [task cancel];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    CoreProtocol *load = LoadOf(task, NO);
    load.status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    load.type = response.MIMEType;
    if (!load.redirected) {
        [load onClientThread:^{
            // The session's cache keeps the responses, so the web view keeps none of its own.
            [load.client URLProtocol:load didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }];
    }
    completion(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    CoreProtocol *load = LoadOf(task, NO);
    load.bytes += data.length;
    if (!load.redirected) [load onClientThread:^{ [load.client URLProtocol:load didLoadData:data]; }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    CoreProtocol *load = LoadOf(task, YES);
    if (!load || load.redirected) return;
    BOOL cancelled = load.stopped && error.code == NSURLErrorCancelled;
    DebugRequest(load.request.HTTPMethod, load.request.URL, load.status, load.type, load.bytes,
                 CFAbsoluteTimeGetCurrent() - load.started, error, cancelled, nil);
    [load onClientThread:^{
        if (error) {
            [load.client URLProtocol:load didFailWithError:error];
        } else {
            [load.client URLProtocolDidFinishLoading:load];
        }
    }];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIWebViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate {
    UIWebView *_web;
    UITextField *_address;
    UIButton *_back;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Before the first web view, which reads it once.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"UserAgent": kUserAgent}];
    NSString *debug = [self folder:NSCachesDirectory named:@"debug"];
    DebugStart(debug, ^{
        __block NSString *status;
        OnCore(YES, ^{ status = TakeString(SFStatus()); });
        return status;
    }, ^{
        __block NSString *log;
        OnCore(YES, ^{ log = TakeString(SFRecentLog()); });
        return log;
    });
    DebugApp(@"start");

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:0.97 alpha:1];
    [self buildScreenIn:root.view];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    _address.text = @"Starting…";
    _address.enabled = NO;

    NSString *data = [self folder:NSApplicationSupportDirectory named:@"SafariFix"];
    NSString *cache = [self folder:NSCachesDirectory named:@"scripts"];
    CFAbsoluteTime starting = CFAbsoluteTimeGetCurrent();
    BOOL firstRun = ![[NSFileManager defaultManager] contentsOfDirectoryAtPath:data error:nil].count;
    OnCore(NO, ^{
        // The core serves the debug record under /debug/, for the PC over USB.
        SFSetTimeZone((int)[NSTimeZone localTimeZone].secondsFromGMT);
        NSString *error = TakeString(SFStart((char *)data.UTF8String, (char *)cache.UTF8String,
                                             (char *)debug.UTF8String, kPort));
        NSString *chain = error ? nil : TakeString(SFTestChain());
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                DebugApp([@"core FAILED to start: " stringByAppendingString:error]);
                self->_address.text = [@"Core failed: " stringByAppendingString:error];
                return;
            }
            [self startSessionWithChain:chain];
            [NSURLProtocol registerClass:[CoreProtocol class]];
            // On the first run the core also makes its root key, which takes a while.
            DebugApp([NSString stringWithFormat:@"core started in %.1f s%@", CFAbsoluteTimeGetCurrent() - starting,
                                                firstRun ? @", with a new root key" : @""]);
            self->_address.enabled = YES;
            self->_address.text = @"";
            [self->_address becomeFirstResponder];
        });
    });
    return YES;
}

- (void)startSessionWithChain:(NSString *)chain {
    // The root is the last of SFTestChain's lines.
    NSString *root = [chain componentsSeparatedByString:@"\n"].lastObject;
    NSData *der = [[NSData alloc] initWithBase64EncodedString:root options:0];
    gRoots = @[CFBridgingRelease(SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der))];
    gLoads = [NSMutableDictionary dictionary];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.connectionProxyDictionary = @{
        @"HTTPEnable": @YES, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @(kPort),
        @"HTTPSEnable": @YES, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @(kPort),
    };
    config.HTTPMaximumConnectionsPerHost = 6;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    gSession = [NSURLSession sessionWithConfiguration:config delegate:[SessionDelegate new] delegateQueue:queue];
}

- (void)buildScreenIn:(UIView *)view {
    CGFloat width = view.bounds.size.width;
    _back = [UIButton buttonWithType:UIButtonTypeSystem];
    _back.frame = CGRectMake(4, 24, 36, 32);
    _back.titleLabel.font = [UIFont systemFontOfSize:28];
    [_back setTitle:@"‹" forState:UIControlStateNormal];
    [_back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:_back];

    _address = [[UITextField alloc] initWithFrame:CGRectMake(44, 24, width - 108, 32)];
    _address.borderStyle = UITextBorderStyleRoundedRect;
    _address.font = [UIFont systemFontOfSize:15];
    _address.placeholder = @"Search or enter website";
    _address.keyboardType = UIKeyboardTypeWebSearch;
    _address.returnKeyType = UIReturnKeyGo;
    _address.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _address.autocorrectionType = UITextAutocorrectionTypeNo;
    _address.clearButtonMode = UITextFieldViewModeWhileEditing;
    _address.delegate = self;
    [view addSubview:_address];

    UIButton *details = [UIButton buttonWithType:UIButtonTypeSystem];
    details.frame = CGRectMake(width - 60, 24, 56, 32);
    details.titleLabel.font = [UIFont systemFontOfSize:15];
    [details setTitle:@"Debug" forState:UIControlStateNormal];
    [details addTarget:self action:@selector(showDetails) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:details];

    _web = [[UIWebView alloc] initWithFrame:CGRectMake(0, 62, width, view.bounds.size.height - 62)];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.scalesPageToFit = YES;
    _web.allowsInlineMediaPlayback = YES;
    _web.delegate = self;
    [view addSubview:_web];
    WatchWebKit(_web);
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    NSString *text = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSURL *url = nil;
    if ([text rangeOfString:@" "].location == NSNotFound && [text rangeOfString:@"."].location != NSNotFound) {
        url = [NSURL URLWithString:[text rangeOfString:@"://"].location == NSNotFound
                                     ? [@"https://" stringByAppendingString:text] : text];
    }
    if (!url) {
        NSString *query = [text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        url = [NSURL URLWithString:[@"https://www.google.com/search?q=" stringByAppendingString:query]];
    }
    [field resignFirstResponder];
    [_web loadRequest:[NSURLRequest requestWithURL:url]];
    return NO;
}

- (void)goBack {
    if (_web.canGoBack) [_web goBack];
}

- (void)showDetails {
    SFDetailsViewController *details = [[SFDetailsViewController alloc] initWithText:^{ return DebugDetails(); }];
    [self.window.rootViewController presentViewController:[[UINavigationController alloc] initWithRootViewController:details]
                                                 animated:YES completion:nil];
}

- (BOOL)webView:(UIWebView *)web shouldStartLoadWithRequest:(NSURLRequest *)request
 navigationType:(UIWebViewNavigationType)type {
    if ([request.URL isEqual:request.mainDocumentURL]) DebugPageStarted(request.URL);
    return YES;
}

- (void)webViewDidStartLoad:(UIWebView *)web {
    _back.enabled = web.canGoBack;
}

- (void)webViewDidFinishLoad:(UIWebView *)web {
    // Once for each frame; the page is done when none is loading.
    if (web.isLoading) return;
    NSString *url = web.request.mainDocumentURL.absoluteString;
    if (!_address.isEditing && url) _address.text = url;
    _back.enabled = web.canGoBack;
    DebugPageFinished(web.request.mainDocumentURL);
}

- (void)webView:(UIWebView *)web didFailLoadWithError:(NSError *)error {
    // Cancelled loads, the protocol's redirects, and WebKit's own interruptions aren't failures.
    if (error.code == NSURLErrorCancelled || error.code == NSUserCancelledError ||
        [error.domain isEqualToString:@"WebKitErrorDomain"]) return;
    DebugPageFailed(error);
}

- (NSString *)folder:(NSSearchPathDirectory)directory named:(NSString *)name {
    NSString *path = [NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

@end

int main(int argc, char *argv[]) {
    // A peer that closes mid-send must fail the send, not kill the app.
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
