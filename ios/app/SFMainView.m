#import "SFMainView.h"

@implementation SFModel
@end

// iOS 10's colors.
static UIColor *RGB(uint32_t hex) {
    return [UIColor colorWithRed:(hex >> 16 & 0xff) / 255.0 green:(hex >> 8 & 0xff) / 255.0 blue:(hex & 0xff) / 255.0
                           alpha:1];
}
static UIColor *Blue(void) { return RGB(0x007aff); }
static UIColor *Green(void) { return RGB(0x4cd964); }
static UIColor *Orange(void) { return RGB(0xff9500); }
static UIColor *Red(void) { return RGB(0xff3b30); }
static UIColor *Grey(void) { return RGB(0x8e8e93); }
static UIColor *Secondary(void) { return RGB(0x6d6d72); }
static UIColor *Background(void) { return RGB(0xefeff4); }

static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

static UIStackView *Stack(UILayoutConstraintAxis axis, CGFloat spacing, NSArray<UIView *> *views) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = axis;
    stack.spacing = spacing;
    stack.alignment = axis == UILayoutConstraintAxisVertical ? UIStackViewAlignmentFill : UIStackViewAlignmentTop;
    return stack;
}

/// content inside a rounded box of color, inset by inset on every side.
static UIView *Box(UIView *content, UIColor *color, CGFloat radius, CGFloat inset) {
    UIView *box = [UIView new];
    box.backgroundColor = color;
    box.layer.cornerRadius = radius;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:box.topAnchor constant:inset],
        [content.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-inset],
        [content.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-inset],
    ]];
    return box;
}

static UIView *Card(UIView *content) { return Box(content, [UIColor whiteColor], 12, 16); }

static UIButton *FilledButton(NSString *title, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = Blue();
    button.layer.cornerRadius = 10;
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitle:title forState:UIControlStateNormal];
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

/// A round badge holding a glyph: a step's number, a check mark, or the status.
@interface SFBadge : UIView
- (instancetype)initWithSize:(CGFloat)size;
- (void)setGlyph:(NSString *)glyph color:(UIColor *)color;
@end

@implementation SFBadge {
    UILabel *_glyph;
}

- (instancetype)initWithSize:(CGFloat)size {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.layer.cornerRadius = size / 2;
    _glyph = Label(size / 2, UIFontWeightBold, [UIColor whiteColor]);
    _glyph.numberOfLines = 1;
    _glyph.textAlignment = NSTextAlignmentCenter;
    _glyph.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_glyph];
    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:size],
        [self.heightAnchor constraintEqualToConstant:size],
        [_glyph.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_glyph.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

- (void)setGlyph:(NSString *)glyph color:(UIColor *)color {
    _glyph.text = glyph;
    self.backgroundColor = color;
}

@end

@implementation SFMainView {
    UIScrollView *_scroll;
    SFBadge *_statusBadge;
    UILabel *_statusTitle, *_statusBody;
    UIView *_certCard;
    SFBadge *_certBadge;
    UILabel *_certBody;
    UIButton *_certButton;
    UIView *_proxyCard;
    SFBadge *_proxyBadge;
    UILabel *_proxyBody, *_proxyAddress;
    UIView *_proxyAddressBox;
    UIButton *_copyButton;
    UIView *_browserCard;
    UILabel *_safariHeader;
    UIView *_renewCard;
    UILabel *_renewTitle, *_renewBody;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = Background();

    UILabel *title = Label(30, UIFontWeightBold, [UIColor blackColor]);
    title.text = @"SafariFix";

    _statusBadge = [[SFBadge alloc] initWithSize:44];
    _statusTitle = Label(22, UIFontWeightSemibold, [UIColor blackColor]);
    _statusBody = Label(15, UIFontWeightRegular, Secondary());
    UIStackView *status = Stack(UILayoutConstraintAxisHorizontal, 14,
                                @[_statusBadge, Stack(UILayoutConstraintAxisVertical, 4, @[_statusTitle, _statusBody])]);

    // Step 1 comes first: with the proxy set and the root untrusted, Safari opens no fixed site at all.
    _certBadge = [[SFBadge alloc] initWithSize:28];
    UILabel *certTitle = Label(17, UIFontWeightSemibold, [UIColor blackColor]);
    certTitle.text = @"Install the certificate";
    _certBody = Label(15, UIFontWeightRegular, Secondary());
    _certButton = FilledButton(@"Install in Safari", self, @selector(installCertificate));
    UIStackView *cert = Stack(UILayoutConstraintAxisHorizontal, 12,
                              @[_certBadge, Stack(UILayoutConstraintAxisVertical, 8, @[certTitle, _certBody, _certButton])]);

    _proxyBadge = [[SFBadge alloc] initWithSize:28];
    UILabel *proxyTitle = Label(17, UIFontWeightSemibold, [UIColor blackColor]);
    proxyTitle.text = @"Send Safari through SafariFix";
    _proxyBody = Label(15, UIFontWeightRegular, Secondary());
    _proxyAddress = Label(14, UIFontWeightRegular, [UIColor blackColor]);
    _proxyAddress.font = [UIFont fontWithName:@"Menlo" size:13];
    // One line, so it reads as one address.
    _proxyAddress.numberOfLines = 1;
    _proxyAddress.adjustsFontSizeToFitWidth = YES;
    _proxyAddress.minimumScaleFactor = 0.6;
    _proxyAddressBox = Box(_proxyAddress, Background(), 8, 10);
    _copyButton = FilledButton(@"Copy the address", self, @selector(copyPACURL));
    UIStackView *proxy = Stack(UILayoutConstraintAxisHorizontal, 12,
                               @[_proxyBadge, Stack(UILayoutConstraintAxisVertical, 8,
                                                    @[proxyTitle, _proxyBody, _proxyAddressBox, _copyButton])]);

    UILabel *browserTitle = Label(17, UIFontWeightSemibold, [UIColor blackColor]);
    browserTitle.text = @"Browser";
    UILabel *browserBody = Label(15, UIFontWeightRegular, Secondary());
    browserBody.text = @"A simple browser inside SafariFix, on any network and with no setup. Pages run slower than "
                        "in Safari.";
    UIButton *browserButton = FilledButton(@"Open the browser", self, @selector(openBrowser));

    // Safari's steps are for Safari alone; the browser needs neither.
    _safariHeader = Label(13, UIFontWeightRegular, Secondary());
    _safariHeader.text = @"TO USE SAFARI AS WELL";

    _renewTitle = Label(17, UIFontWeightSemibold, [UIColor blackColor]);
    _renewBody = Label(15, UIFontWeightRegular, Secondary());
    _renewBody.text = @"After that it won't open until it's installed again from the PC.";

    UIButton *details = [UIButton buttonWithType:UIButtonTypeSystem];
    details.titleLabel.font = [UIFont systemFontOfSize:15];
    [details setTitle:@"Details" forState:UIControlStateNormal];
    [details addTarget:self action:@selector(showDetails) forControlEvents:UIControlEventTouchUpInside];

    _certCard = Card(cert);
    _proxyCard = Card(proxy);
    _browserCard = Card(Stack(UILayoutConstraintAxisVertical, 8, @[browserTitle, browserBody, browserButton]));
    _renewCard = Card(Stack(UILayoutConstraintAxisVertical, 4, @[_renewTitle, _renewBody]));
    UIStackView *page = Stack(UILayoutConstraintAxisVertical, 16,
                              @[title, Card(status), _browserCard, _safariHeader, _certCard, _proxyCard, _renewCard,
                                details]);
    page.translatesAutoresizingMaskIntoConstraints = NO;

    _scroll = [UIScrollView new];
    _scroll.alwaysBounceVertical = YES;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:page];
    [self addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        // Below the status bar.
        [page.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:36],
        [page.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-16],
        [page.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [page.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [page.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-32],
    ]];
    return self;
}

- (void)setStatus:(NSString *)glyph color:(UIColor *)color title:(NSString *)title body:(NSString *)body {
    [_statusBadge setGlyph:glyph color:color];
    _statusTitle.text = title;
    _statusBody.text = body;
    _statusBody.hidden = body.length == 0;
}

- (void)show:(SFModel *)m {
    BOOL running = m.core == SFCoreRunning;
    BOOL checking = running && (m.trusted == SFCheckUnknown || m.proxySet == SFCheckUnknown);
    BOOL certDone = m.trusted == SFCheckYes, proxyDone = m.proxySet == SFCheckYes;
    BOOL ready = running && certDone && proxyDone;

    if (m.core == SFCoreStarting) {
        [self setStatus:@"…" color:Grey() title:@"Starting"
                   body:@"The first start makes SafariFix's certificate, which can take a minute."];
    } else if (m.core == SFCoreFailed) {
        [self setStatus:@"!" color:Red() title:@"SafariFix couldn't start"
                   body:[NSString stringWithFormat:@"%@\n\nClose SafariFix in the app switcher, then open it again.",
                         m.failure]];
    } else if (checking) {
        [self setStatus:@"…" color:Grey() title:@"Checking the setup" body:nil];
    } else if (ready) {
        [self setStatus:@"✓" color:Green() title:@"Ready"
                   body:@"Open the browser below, or use Safari as usual. Keep SafariFix in the app switcher: when "
                         "you close apps, swipe away only Safari."];
    } else if (proxyDone) {
        [self setStatus:@"!" color:Red() title:@"Safari can't open most sites"
                   body:@"Safari goes through SafariFix but doesn't trust its certificate yet. Finish step 1 below, "
                         "or turn the Wi-Fi proxy off."];
    } else {
        [self setStatus:@"✓" color:Green() title:@"Ready"
                   body:certDone ? @"Open the browser below. Safari opens sites unfixed until you finish its last "
                                    "step."
                                 : @"Open the browser below. Safari opens sites unfixed unless you take its two "
                                    "steps."];
    }

    BOOL steps = running && !checking && !ready;
    _safariHeader.hidden = _certCard.hidden = _proxyCard.hidden = !steps;
    [_certBadge setGlyph:certDone ? @"✓" : @"1" color:certDone ? Green() : Blue()];
    _certBody.text = certDone ? @"Installed and trusted."
        : [NSString stringWithFormat:@"Tap Install in Safari and follow the page there. Last, in Settings → "
                                      "General → About → Certificate Trust Settings, turn on “%@” and tap Continue.",
                                      m.rootName];
    _certButton.hidden = certDone;
    [_proxyBadge setGlyph:proxyDone ? @"✓" : @"2" color:proxyDone ? Green() : Blue()];
    _proxyBody.text = proxyDone ? @"Set for this Wi-Fi network."
        : @"In Settings → Wi-Fi, tap ⓘ next to your network. Under HTTP Proxy, tap Auto, and paste this address "
           "as the URL:";
    _proxyAddress.text = m.pacURL;
    _proxyAddressBox.hidden = _copyButton.hidden = proxyDone;
    _browserCard.hidden = !running;

    _renewCard.hidden = m.signedUntil == nil;
    if (m.signedUntil) {
        // In English, like the rest of the screen.
        NSDateFormatter *format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
        [format setLocalizedDateFormatFromTemplate:@"EEEdMMMHHmm"];
        BOOL soon = [m.signedUntil timeIntervalSinceNow] < 2 * 24 * 3600;
        _renewTitle.text = [NSString stringWithFormat:soon ? @"Renew by %@" : @"Works until %@",
                            [format stringFromDate:m.signedUntil]];
        _renewTitle.textColor = soon ? Orange() : [UIColor blackColor];
    }
}

- (void)showCopied {
    [_copyButton setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self->_copyButton setTitle:@"Copy the address" forState:UIControlStateNormal];
    });
}

- (void)installCertificate { [self.actions installCertificate]; }
- (void)copyPACURL { [self.actions copyPACURL]; }
- (void)openBrowser { [self.actions openBrowser]; }
- (void)showDetails { [self.actions showDetails]; }

@end
