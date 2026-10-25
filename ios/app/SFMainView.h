#import <UIKit/UIKit.h>

// The main screen: what the user needs to know and do, and nothing else. The counts, the log and the raw checks
// are on the Details screen.

typedef NS_ENUM(NSInteger, SFCore) { SFCoreStarting, SFCoreRunning, SFCoreFailed };
typedef NS_ENUM(NSInteger, SFCheck) { SFCheckUnknown, SFCheckNo, SFCheckYes };

/// What the main screen shows.
@interface SFModel : NSObject
@property (nonatomic) SFCore core;
/// Why the core couldn't start.
@property (nonatomic, copy) NSString *failure;
/// The root certificate's name, as Certificate Trust Settings shows it.
@property (nonatomic, copy) NSString *rootName;
/// Whether iOS trusts the root for websites, as Safari needs.
@property (nonatomic) SFCheck trusted;
/// Whether this Wi-Fi network sends Safari through SafariFix's PAC file.
@property (nonatomic) SFCheck proxySet;
@property (nonatomic, copy) NSString *pacURL;
/// When the app's signing runs out, or nil if unknown.
@property (nonatomic, strong) NSDate *signedUntil;
@end

@protocol SFMainViewActions <NSObject>
- (void)installCertificate;
- (void)copyPACURL;
- (void)openBrowser;
- (void)showDetails;
@end

@interface SFMainView : UIView
@property (nonatomic, weak) id<SFMainViewActions> actions;
- (void)show:(SFModel *)model;
/// Briefly confirms that the PAC URL was copied.
- (void)showCopied;
@end
