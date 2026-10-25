#import <UIKit/UIKit.h>

// The Details screen: everything for debugging that the main screen leaves out, as plain text that refreshes every
// 2 seconds and copies in one tap.
@interface SFDetailsViewController : UIViewController
- (instancetype)initWithText:(NSString *(^)(void))text;
@end
