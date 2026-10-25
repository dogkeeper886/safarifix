#import <CFNetwork/CFNetwork.h>
#import <Security/Security.h>

#import "SFChecks.h"

/// Whether one proxy settings dictionary is Auto with a PAC URL on 127.0.0.1:port, described in found.
static BOOL UsesPAC(NSDictionary *settings, int port, NSString **found) {
    NSString *pac = settings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigURLString];
    if ([settings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigEnable] boolValue] && pac) {
        *found = [@"Auto, " stringByAppendingString:pac];
        NSURL *url = [NSURL URLWithString:pac];
        return ([url.host isEqualToString:@"127.0.0.1"] || [url.host isEqualToString:@"localhost"]) &&
               url.port.intValue == port;
    }
    if ([settings[(__bridge NSString *)kCFNetworkProxiesHTTPEnable] boolValue]) {
        *found = [NSString stringWithFormat:@"Manual, %@:%@", settings[(__bridge NSString *)kCFNetworkProxiesHTTPProxy],
                  settings[(__bridge NSString *)kCFNetworkProxiesHTTPPort]];
    }
    return NO;
}

SFCheck SFCheckProxy(int port, NSString **found) {
    NSDictionary *settings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSString *what = @"Off";
    if (UsesPAC(settings, port, &what)) {
        *found = what;
        return SFCheckYes;
    }
    // iOS also lists each network interface's own settings.
    NSDictionary *scoped = settings[@"__SCOPED__"];
    for (NSString *interface in scoped) {
        NSString *scopedWhat = what;
        if (UsesPAC(scoped[interface], port, &scopedWhat)) {
            *found = [NSString stringWithFormat:@"%@ on %@", scopedWhat, interface];
            return SFCheckYes;
        }
    }
    *found = what;
    return SFCheckNo;
}

SFCheck SFCheckTrust(NSString *chain, NSString **found) {
    NSArray<NSString *> *lines = [chain componentsSeparatedByString:@"\n"];
    NSString *host = lines.firstObject;
    NSMutableArray *certs = [NSMutableArray array];
    for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
        NSData *der = [[NSData alloc] initWithBase64EncodedString:line options:0];
        SecCertificateRef cert = der ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der) : NULL;
        if (cert) [certs addObject:CFBridgingRelease(cert)];
    }
    if (certs.count != 2) {
        *found = @"no certificate from the core";
        return SFCheckUnknown;
    }
    // The root goes along to build the chain; only Certificate Trust Settings makes it an anchor.
    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
    SecTrustRef trust = NULL;
    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)certs, policy, &trust);
    CFRelease(policy);
    if (status != errSecSuccess) {
        *found = [NSString stringWithFormat:@"SecTrustCreateWithCertificates: %d", (int)status];
        return SFCheckUnknown;
    }
    SecTrustResultType result = kSecTrustResultInvalid;
    status = SecTrustEvaluate(trust, &result);
    CFRelease(trust);
    if (status != errSecSuccess) {
        *found = [NSString stringWithFormat:@"SecTrustEvaluate: %d", (int)status];
        return SFCheckUnknown;
    }
    BOOL trusted = result == kSecTrustResultUnspecified || result == kSecTrustResultProceed;
    *found = [NSString stringWithFormat:@"%@ (SecTrustResultType %u)", trusted ? @"trusted" : @"not trusted",
              (unsigned)result];
    return trusted ? SFCheckYes : SFCheckNo;
}

NSDate *SFSignedUntil(void) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *profile = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!profile) return nil;
    // The profile is a signed message around a property list.
    NSRange start = [profile rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0
                                   range:NSMakeRange(0, profile.length)];
    NSRange end = [profile rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards
                                 range:NSMakeRange(0, profile.length)];
    if (start.location == NSNotFound || end.location == NSNotFound || end.location < start.location) return nil;
    NSData *plist = [profile subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
    NSDictionary *info = [NSPropertyListSerialization propertyListWithData:plist options:0 format:NULL error:NULL];
    id date = [info isKindOfClass:[NSDictionary class]] ? info[@"ExpirationDate"] : nil;
    return [date isKindOfClass:[NSDate class]] ? date : nil;
}
