#import <UIKit/UIKit.h>

// The browser inside SafariFix: a bare browser in a UIWebView that sends every request through the core, in the app,
// so it needs neither the Wi-Fi proxy setting nor the trusted certificate that Safari does. Each page's requests,
// script errors and WebKit's messages go to the debug record (SFDebugLog.h). UIWebView, unlike WKWebView, loads in
// the app's own process, which is what lets the app see its requests; the price is JavaScript without the JIT.

/// Sends the web views' requests through the core's proxy on 127.0.0.1:port, trusting root, the core's root
/// certificate in DER, besides the system's roots. Call once, on the main thread, once the core listens.
void SFBrowserStart(int port, NSData *root);

/// The browser's screen: an address bar over the page. The app keeps one, so the page stays while the setup screen
/// shows.
@interface SFBrowserViewController : UIViewController
@end
