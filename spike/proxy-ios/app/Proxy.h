#import <Foundation/Foundation.h>

/// The proxy test's proxy on 127.0.0.1: tunnels Safari's HTTPS and forwards its plain HTTP without changing either,
/// and serves /proxy.pac, the PAC file that points Safari at it.
@interface Proxy : NSObject

- (instancetype)initWithPort:(uint16_t)port;
/// Returns NO when the port can't be opened.
- (BOOL)start;
/// Connections, bytes and hosts so far, for the log.
- (NSString *)stats;

@end
