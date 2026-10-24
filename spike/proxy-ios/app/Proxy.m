#import "Proxy.h"

#import <errno.h>
#import <netdb.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

/// A request head longer than this is refused.
static const size_t kMaxHead = 16384;
/// A tunnel idle this long closes, so a forgotten connection doesn't hold a thread.
static const int kIdleMilliseconds = 120000;

static void NoSigPipe(int fd) {
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
}

static BOOL SendAll(int fd, const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    while (length > 0) {
        ssize_t sent = send(fd, p, length, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return NO;
        p += sent;
        length -= (size_t)sent;
    }
    return YES;
}

/// Returns a connected socket to host:port, or -1.
static int ConnectTo(NSString *host, NSString *port) {
    struct addrinfo hints = {0}, *found = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.UTF8String, port.UTF8String, &hints, &found) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *a = found; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(found);
    if (fd >= 0) {
        NoSigPipe(fd);
        int yes = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
    }
    return fd;
}

/// Splits "host:port", "[v6]:port" or "host" into its parts.
static void SplitAuthority(NSString *authority, NSString *defaultPort, NSString **host, NSString **port) {
    *host = authority;
    *port = defaultPort;
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    NSRange bracket = [authority rangeOfString:@"]" options:NSBackwardsSearch];
    if (colon.location != NSNotFound && (bracket.location == NSNotFound || colon.location > bracket.location)) {
        *host = [authority substringToIndex:colon.location];
        *port = [authority substringFromIndex:colon.location + 1];
    }
    *host = [*host stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]"]];
}

@implementation Proxy {
    uint16_t _port;
    NSData *_pac;
    NSLock *_lock;
    // Guarded by _lock.
    NSUInteger _connections, _open;
    unsigned long long _bytes;
    NSMutableSet<NSString *> *_hosts;
}

- (instancetype)initWithPort:(uint16_t)port {
    if (!(self = [super init])) return nil;
    _port = port;
    // DIRECT after the proxy keeps Safari online while this app isn't running.
    NSString *pac = [NSString stringWithFormat:
        @"function FindProxyForURL(url, host) { return \"PROXY 127.0.0.1:%u; DIRECT\"; }\n", port];
    _pac = [pac dataUsingEncoding:NSUTF8StringEncoding];
    _lock = [NSLock new];
    _hosts = [NSMutableSet set];
    return self;
}

- (BOOL)start {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address = {0};
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons(_port);
    // Loopback only: no other device on the WiFi can use the proxy.
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 64) != 0) {
        close(fd);
        return NO;
    }
    [NSThread detachNewThreadWithBlock:^{
        for (;;) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                NSLog(@"proxy-test: accept failed: %s", strerror(errno));
                return;
            }
            NoSigPipe(client);
            // One thread per connection; a tunnel blocks its thread for as long as it lasts.
            [NSThread detachNewThreadWithBlock:^{ [self serve:client]; }];
        }
    }];
    return YES;
}

- (NSString *)stats {
    [_lock lock];
    NSString *stats = [NSString stringWithFormat:@"%lu connections (%lu open), %llu KB, %lu hosts",
                       (unsigned long)_connections, (unsigned long)_open, _bytes / 1024, (unsigned long)_hosts.count];
    [_lock unlock];
    return stats;
}

- (void)serve:(int)fd {
    [_lock lock];
    _connections++;
    _open++;
    [_lock unlock];
    [self handle:fd];
    close(fd);
    [_lock lock];
    _open--;
    [_lock unlock];
}

- (void)handle:(int)fd {
    // Read the request head; whatever follows it in the same read belongs to the body or the tunnel.
    NSMutableData *buffer = [NSMutableData data];
    NSRange end = NSMakeRange(NSNotFound, 0);
    NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t chunk[4096];
    while (end.location == NSNotFound) {
        if (buffer.length > kMaxHead) return;
        ssize_t n = recv(fd, chunk, sizeof chunk, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        end = [buffer rangeOfData:terminator options:0 range:NSMakeRange(0, buffer.length)];
    }
    // Latin-1 maps every byte to one character, so the head survives the round trip unchanged.
    NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)]
                                           encoding:NSISOLatin1StringEncoding];
    NSData *rest = [buffer subdataWithRange:NSMakeRange(NSMaxRange(end), buffer.length - NSMaxRange(end))];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    if (requestLine.count != 3) return;
    NSString *method = requestLine[0], *target = requestLine[1], *version = requestLine[2];

    if ([method isEqualToString:@"CONNECT"]) {
        NSString *host, *port;
        SplitAuthority(target, @"443", &host, &port);
        [self noteHost:target method:method];
        int upstream = ConnectTo(host, port);
        if (upstream < 0) {
            const char *reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n";
            SendAll(fd, reply, strlen(reply));
            return;
        }
        const char *reply = "HTTP/1.1 200 Connection established\r\n\r\n";
        if (SendAll(fd, reply, strlen(reply)) && (rest.length == 0 || SendAll(upstream, rest.bytes, rest.length))) {
            [self pipe:fd with:upstream];
        }
        close(upstream);
        return;
    }

    if ([target hasPrefix:@"http://"]) {
        NSString *afterScheme = [target substringFromIndex:7];
        NSRange slash = [afterScheme rangeOfString:@"/"];
        NSString *authority = slash.location == NSNotFound ? afterScheme : [afterScheme substringToIndex:slash.location];
        NSString *path = slash.location == NSNotFound ? @"/" : [afterScheme substringFromIndex:slash.location];
        NSString *host, *port;
        SplitAuthority(authority, @"80", &host, &port);
        [self noteHost:authority method:method];
        int upstream = ConnectTo(host, port);
        if (upstream < 0) {
            const char *reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            SendAll(fd, reply, strlen(reply));
            return;
        }
        // One request per connection: the next request on a kept-alive connection could be for another host.
        NSMutableString *out = [NSMutableString stringWithFormat:@"%@ %@ %@\r\n", method, path, version];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *lower = lines[i].lowercaseString;
            if ([lower hasPrefix:@"proxy-connection:"] || [lower hasPrefix:@"connection:"] || [lower hasPrefix:@"keep-alive:"]) {
                continue;
            }
            [out appendFormat:@"%@\r\n", lines[i]];
        }
        [out appendString:@"Connection: close\r\n\r\n"];
        NSData *outHead = [out dataUsingEncoding:NSISOLatin1StringEncoding];
        if (SendAll(upstream, outHead.bytes, outHead.length) && (rest.length == 0 || SendAll(upstream, rest.bytes, rest.length))) {
            [self pipe:fd with:upstream];
        }
        close(upstream);
        return;
    }

    if ([target hasPrefix:@"/proxy.pac"]) {
        NSLog(@"proxy-test: served the PAC file");
        NSString *reply = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                           @"Content-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)_pac.length];
        NSData *replyHead = [reply dataUsingEncoding:NSASCIIStringEncoding];
        if (SendAll(fd, replyHead.bytes, replyHead.length)) SendAll(fd, _pac.bytes, _pac.length);
        return;
    }

    const char *reply = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    SendAll(fd, reply, strlen(reply));
}

/// Copies bytes both ways until both sides finish or the tunnel idles out.
- (void)pipe:(int)a with:(int)b {
    struct pollfd fds[2] = {{a, POLLIN, 0}, {b, POLLIN, 0}};
    BOOL reading[2] = {YES, YES};
    uint8_t buffer[32768];
    while (reading[0] || reading[1]) {
        fds[0].events = reading[0] ? POLLIN : 0;
        fds[1].events = reading[1] ? POLLIN : 0;
        int ready = poll(fds, 2, kIdleMilliseconds);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return;
        for (int i = 0; i < 2; i++) {
            if (!reading[i] || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = recv(fds[i].fd, buffer, sizeof buffer, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                // This side finished sending; pass that on, and keep the other direction open.
                reading[i] = NO;
                shutdown(fds[1 - i].fd, SHUT_WR);
                continue;
            }
            if (!SendAll(fds[1 - i].fd, buffer, (size_t)n)) return;
            [_lock lock];
            _bytes += (unsigned long long)n;
            [_lock unlock];
        }
    }
}

- (void)noteHost:(NSString *)host method:(NSString *)method {
    [_lock lock];
    BOOL isNew = ![_hosts containsObject:host];
    if (isNew) [_hosts addObject:host];
    [_lock unlock];
    if (isNew) NSLog(@"proxy-test: %@ %@", method, host);
}

@end
