#import <Foundation/Foundation.h>

// The browser's debug record: one timeline of what each page did, its requests and console messages, and of the
// app's memory, with the time of each line. It stays in memory and goes every 2 seconds to log.txt, with the counts in
// summary.txt and the core's own log in core.txt, in a folder the core serves under /debug/, so the PC reads them over
// USB. The last run's log.txt stays as previous.txt, to read after a crash. Every function is safe on any thread, and
// none calls into the core itself.

/// Starts the record in folder, moving the last run's log to previous.txt, and samples memory every 5 seconds.
/// coreStatus and coreLog, called before each write on a utility queue, give the core's status and log lines.
void DebugStart(NSString *folder, NSString *(^coreStatus)(void), NSString *(^coreLog)(void));

/// A line about the app, which also goes to the phone's log.
void DebugApp(NSString *line);

/// The main frame starts loading a page.
void DebugPageStarted(NSURL *url);
/// The page and all its frames finished loading, at url after any redirects.
void DebugPageFinished(NSURL *url);
/// The page failed to load.
void DebugPageFailed(NSError *error);

/// One request's outcome: its status and size, or the error that failed it, or that the page cancelled it, or the
/// redirect it got.
void DebugRequest(NSString *method, NSURL *url, NSInteger status, NSString *type, long long bytes, double seconds,
                  NSError *error, BOOL cancelled, NSURL *redirect);

/// A page's message: an error, a failed or blocked load, or a console call, with keys named as WebKit names them for
/// UIKit. The page watcher adds "frame": "page " or "frame " and the URL of the frame it came from; WebKit's own
/// messages come with "webkit": @YES.
void DebugConsole(NSDictionary *message);

/// The Details screen's text: the counts, the timeline's last lines, the previous run's last lines and the core's log.
NSString *DebugDetails(void);

/// A URL short enough for a log line, without its query, which may hold what the user typed.
NSString *DebugShortURL(NSURL *url);
