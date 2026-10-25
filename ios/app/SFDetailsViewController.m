#import "SFDetailsViewController.h"

@implementation SFDetailsViewController {
    NSString *(^_text)(void);
    UITextView *_view;
    NSTimer *_timer;
}

- (instancetype)initWithText:(NSString *(^)(void))text {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _text = [text copy];
    self.title = @"Details";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(copyText)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    return self;
}

- (void)loadView {
    _view = [UITextView new];
    _view.editable = NO;
    _view.font = [UIFont fontWithName:@"Menlo" size:11];
    _view.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    self.view = _view;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)refresh {
    // Keep the reader's place while the text grows.
    CGPoint offset = _view.contentOffset;
    _view.text = _text();
    _view.contentOffset = offset;
}

- (void)copyText {
    [UIPasteboard generalPasteboard].string = _text();
    self.navigationItem.leftBarButtonItem.title = @"Copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self.navigationItem.leftBarButtonItem.title = @"Copy";
    });
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
