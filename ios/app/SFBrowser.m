#import <JavaScriptCore/JavaScriptCore.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "SFBrowser.h"
#import "SFDebugLog.h"
#import "SFDetailsViewController.h"

// Safari's on iOS 10.3.4, read from the phone, so sites treat the browser as Safari.
static NSString *const kUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 10_3_4 like Mac OS X) AppleWebKit/603.3.8 "
                                     "(KHTML, like Gecko) Version/10.0 Mobile/14G61 Safari/602.1";
// Marks a request the protocol already passed on, so the session's own load doesn't come back to it.
static NSString *const kHandled = @"SafariFixHandled";
// How long the page stays while the app is in the background: long enough to read a sign-in code in another app.
// After that, or at once on a memory warning, the browser lets go of it, so that iOS keeps SafariFix running for
// Safari rather than closing it for its memory.
static const NSTimeInterval kKeepInBackground = 120;

/// Reports a page's script errors, failed and blocked loads, and console calls to the debug record. It runs in each
/// frame as its JavaScript starts, before the page's own scripts, and takes the report function off the page.
static NSString *const kWatchScript = @
"(function () {\n"
"  var report = window.__safarifixReport;\n"
"  try { delete window.__safarifixReport; } catch (e) {}\n"
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
        SFDebugConsole(tagged);
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
        SFDebugApp(@"WebKit's messages can't be watched on this iOS");
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gWebKitOriginal = (void *)method_setImplementation(method, (IMP)WebKitMessage); });
    ((void (*)(id, SEL, BOOL))objc_msgSend)(webView, allow, YES);
}

@implementation NSObject (SFBrowserWatch)

// WebKit calls this on the web view's frame load delegate, on the thread that runs JavaScript, as each frame's
// JavaScript starts. UIKit's delegate doesn't have it, so this category answers. The context isn't kept: it would keep
// the page alive.
- (void)webView:(id)webView didCreateJavaScriptContext:(JSContext *)context forFrame:(id)frame {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SFDebugApp(@"watching pages' scripts"); });
    context[@"__safarifixReport"] = ^(NSString *level, NSString *source, NSString *text, NSString *url, NSNumber *line,
                                      NSNumber *column, NSString *where) {
        SFDebugConsole(@{@"message": text ?: @"", @"MessageLevel": level ?: @"?", @"MessageSource": source ?: @"?",
                         @"sourceURL": url ?: @"", @"lineNumber": line ?: @0, @"columnNumber": column ?: @0,
                         @"frame": where ?: @""});
    };
    [context evaluateScript:kWatchScript];
}

@end

@class SFCoreProtocol;

/// The session every request goes out on, and which protocol instance each of its tasks serves.
static NSURLSession *gSession;
static NSMutableDictionary<NSNumber *, SFCoreProtocol *> *gLoads;
/// The core's root certificate, which signs the certificates the core shows for the sites it fixes.
static NSArray *gRoots;

@interface SFCoreProtocol : NSURLProtocol
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

@implementation SFCoreProtocol

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
@interface SFSessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation SFSessionDelegate

static SFCoreProtocol *LoadOf(NSURLSessionTask *task, BOOL remove) {
    @synchronized (gLoads) {
        SFCoreProtocol *load = gLoads[@(task.taskIdentifier)];
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
        SFDebugApp([NSString stringWithFormat:@"untrusted certificate for %@ (%u)", challenge.protectionSpace.host,
                    (unsigned)result]);
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completion {
    // The web view follows redirects itself, so it shows the new URL and its request comes back through the protocol.
    SFCoreProtocol *load = LoadOf(task, NO);
    NSMutableURLRequest *next = [request mutableCopy];
    [NSURLProtocol removePropertyForKey:kHandled inRequest:next];
    load.redirected = YES;
    SFDebugRequest(load.request.HTTPMethod, load.request.URL, response.statusCode, nil, 0,
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
    SFCoreProtocol *load = LoadOf(task, NO);
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
    SFCoreProtocol *load = LoadOf(task, NO);
    load.bytes += data.length;
    if (!load.redirected) [load onClientThread:^{ [load.client URLProtocol:load didLoadData:data]; }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    SFCoreProtocol *load = LoadOf(task, YES);
    if (!load || load.redirected) return;
    BOOL cancelled = load.stopped && error.code == NSURLErrorCancelled;
    SFDebugRequest(load.request.HTTPMethod, load.request.URL, load.status, load.type, load.bytes,
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

void SFBrowserStart(int port, NSData *root) {
    // Before the first web view, which reads it once.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"UserAgent": kUserAgent}];
    SecCertificateRef cert = root ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)root) : NULL;
    gRoots = cert ? @[CFBridgingRelease(cert)] : @[];
    gLoads = [NSMutableDictionary dictionary];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.connectionProxyDictionary = @{
        @"HTTPEnable": @YES, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @(port),
        @"HTTPSEnable": @YES, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @(port),
    };
    config.HTTPMaximumConnectionsPerHost = 6;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    gSession = [NSURLSession sessionWithConfiguration:config delegate:[SFSessionDelegate new] delegateQueue:queue];
    [NSURLProtocol registerClass:[SFCoreProtocol class]];
}

static UIButton *BarButton(NSString *title, CGFloat size, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont systemFontOfSize:size];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@interface SFBrowserViewController () <UIWebViewDelegate, UITextFieldDelegate>
@end

@implementation SFBrowserViewController {
    UIWebView *_web;
    UITextField *_address;
    UIButton *_done, *_back, *_debug;
    // The page the browser let go of in the background, to open again when it shows.
    NSURL *_unloaded;
    NSTimer *_unloadTimer;
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    view.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:0.97 alpha:1];
    _done = BarButton(@"Done", 15, self, @selector(done));
    [view addSubview:_done];
    _back = BarButton(@"‹", 28, self, @selector(goBack));
    _back.enabled = NO;
    [view addSubview:_back];

    _address = [UITextField new];
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

    _debug = BarButton(@"Debug", 15, self, @selector(showDetails));
    [view addSubview:_debug];
    self.view = view;
    [self makeWebView];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [center addObserver:self selector:@selector(willEnterForeground) name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    [center addObserver:self selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];
}

- (void)makeWebView {
    _web = [UIWebView new];
    _web.scalesPageToFit = YES;
    _web.allowsInlineMediaPlayback = YES;
    _web.delegate = self;
    [self.view addSubview:_web];
    [self.view setNeedsLayout];
    WatchWebKit(_web);
}

/// Lays out the bar and the page for the phone's orientation. iOS hides the status bar in landscape, and the bar
/// moves up into its place.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat top = self.topLayoutGuide.length + 4;
    _done.frame = CGRectMake(4, top, 46, 32);
    _back.frame = CGRectMake(50, top, 28, 32);
    _address.frame = CGRectMake(80, top, size.width - 140, 32);
    _debug.frame = CGRectMake(size.width - 58, top, 54, 32);
    _web.frame = CGRectMake(0, top + 38, size.width, size.height - top - 38);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self openUnloaded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_web.request && !_unloaded) [_address becomeFirstResponder];
}

- (void)didEnterBackground {
    [_unloadTimer invalidate];
    _unloadTimer = [NSTimer scheduledTimerWithTimeInterval:kKeepInBackground target:self selector:@selector(unload)
                                                  userInfo:nil repeats:NO];
}

- (void)willEnterForeground {
    [_unloadTimer invalidate];
    _unloadTimer = nil;
    if (self.view.window) [self openUnloaded];
}

- (void)memoryWarning {
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) [self unload];
}

/// Lets go of the page, with its web view, and keeps its address to open it again.
- (void)unload {
    [_unloadTimer invalidate];
    _unloadTimer = nil;
    NSURL *url = _web.request.mainDocumentURL;
    if (!_web || !url) return;
    _unloaded = url;
    _web.delegate = nil;
    [_web stopLoading];
    [_web removeFromSuperview];
    _web = nil;
    _back.enabled = NO;
    SFDebugApp([@"let go of the page in the background: " stringByAppendingString:SFDebugShortURL(url)]);
}

- (void)openUnloaded {
    if (!_unloaded) return;
    NSURL *url = _unloaded;
    _unloaded = nil;
    [self makeWebView];
    [_web loadRequest:[NSURLRequest requestWithURL:url]];
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
    _unloaded = nil;
    if (!_web) [self makeWebView];
    [_web loadRequest:[NSURLRequest requestWithURL:url]];
    return NO;
}

- (void)done {
    [_address resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)goBack {
    if (_web.canGoBack) [_web goBack];
}

- (void)showDetails {
    SFDetailsViewController *details = [[SFDetailsViewController alloc] initWithText:^{ return SFDebugDetails(); }];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:details] animated:YES
                     completion:nil];
}

- (BOOL)webView:(UIWebView *)web shouldStartLoadWithRequest:(NSURLRequest *)request
 navigationType:(UIWebViewNavigationType)type {
    if ([request.URL isEqual:request.mainDocumentURL]) SFDebugPageStarted(request.URL);
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
    SFDebugPageFinished(web.request.mainDocumentURL);
}

- (void)webView:(UIWebView *)web didFailLoadWithError:(NSError *)error {
    // Cancelled loads, the protocol's redirects, and WebKit's own interruptions aren't failures.
    if (error.code == NSURLErrorCancelled || error.code == NSUserCancelledError ||
        [error.domain isEqualToString:@"WebKitErrorDomain"]) return;
    SFDebugPageFailed(error);
}

@end
