#import <Foundation/Foundation.h>

#import "SFMainView.h"

// The checks behind the main screen's steps. Each also describes what it found, for the Details screen.

/// Whether the current network's proxy setting is Auto with a PAC URL on 127.0.0.1:port.
SFCheck SFCheckProxy(int port, NSString **found);

/// Whether iOS trusts the site certificate in chain, from the core's SFTestChain, for its site, as Safari does.
/// Slow enough to keep off the main thread.
SFCheck SFCheckTrust(NSString *chain, NSString **found);

/// When the app's signing runs out, from the provisioning profile that signing embedded, or nil.
NSDate *SFSignedUntil(void);
