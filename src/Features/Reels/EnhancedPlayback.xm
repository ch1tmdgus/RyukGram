#import "../../Utils.h"
#import "../../InstagramHeaders.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// When tap control is set to pause/play, these enhancements activate:
// - Mute sub-toggle hidden (only play/pause icon visible)
// - Audio forced on in reels tab
// - Play/pause indicator hidden when video plays (fixes IG bug after hold/zoom)
// - Playback toggle synced with overlay visibility during hold/zoom

static BOOL sciIsPausePlayMode() {
    return [[SCIUtils getStringPref:@"reels_tap_control"] isEqualToString:@"pause"];
}

static BOOL sciIsInReelsTab = NO;

// ============ FIND PLAYBACK VIEW ============
// Handles two IG A/B test variants:
// 1. IGSundialPlaybackToggleView wrapper (contains play + mute subviews)
// 2. Standalone IGDSMediaIconButton (no wrapper)

static UIView * _Nullable sciFindPlaybackView(UIView *videoCell) {
    if (!videoCell) return nil;
    Class toggleClass = objc_getClass("IGSundialPlaybackToggle.IGSundialPlaybackToggleView");
    Class iconBtnClass = NSClassFromString(@"IGDSMediaIconButton");
    UIView *fallbackIconBtn = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:videoCell];
    for (int d = 0; d < 6; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (UIView *v in stack) {
            for (UIView *sub in v.subviews) {
                if (toggleClass && [sub isKindOfClass:toggleClass]) return sub;
                if (iconBtnClass && [sub isKindOfClass:iconBtnClass] &&
                    sub.frame.size.width > 50 && sub.frame.size.height > 50 &&
                    !sub.hidden && sub.frame.origin.x > 100) {
                    fallbackIconBtn = sub;
                }
                [next addObject:sub];
            }
        }
        stack = next;
    }
    return fallbackIconBtn;
}

// ============ KVO: SYNC PLAYBACK VIEW WITH OVERLAY ============
// IG animates the overlay container via Core Animation during hold/zoom.
// The download button (tag 1337) is inside the container so it hides automatically.
// The playback toggle is in a separate view branch — we KVO the download
// button's layer.opacity and sync the toggle to match.

@interface SCIOpacityObserver : NSObject
@end

@implementation SCIOpacityObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (![keyPath isEqualToString:@"opacity"]) return;
    CGFloat opacity = [[change objectForKey:NSKeyValueChangeNewKey] floatValue];
    CALayer *layer = (CALayer *)object;
    UIView *dlBtn = (layer.delegate && [layer.delegate isKindOfClass:[UIView class]]) ? (UIView *)layer.delegate : nil;
    if (!dlBtn) return;
    UIView *videoCell = dlBtn.superview;
    while (videoCell && ![NSStringFromClass([videoCell class]) containsString:@"VideoCell"])
        videoCell = videoCell.superview;
    UIView *playView = sciFindPlaybackView(videoCell);
    if (playView) playView.layer.opacity = opacity;
}
@end

static SCIOpacityObserver *sciObserver = nil;
static NSHashTable *sciObservedLayers = nil;

static void sciSetupKVO(UIView *ufi) {
    UIView *parent = ufi.superview;
    if (!parent) return;
    UIView *dlBtn = [parent viewWithTag:1337];
    if (!dlBtn) return;
    if (!sciObserver) sciObserver = [[SCIOpacityObserver alloc] init];
    if (!sciObservedLayers) sciObservedLayers = [NSHashTable weakObjectsHashTable];
    if ([sciObservedLayers containsObject:dlBtn.layer]) return;
    [dlBtn.layer addObserver:sciObserver forKeyPath:@"opacity"
                     options:NSKeyValueObservingOptionNew context:NULL];
    [sciObservedLayers addObject:dlBtn.layer];
}

// ============ HIDE PLAY INDICATOR WHEN VIDEO PLAYS ============
// After hold/zoom clear mode, IG resumes but leaves the play indicator visible.
// We hide it when the video actually starts playing or unpauses.

%hook IGSundialViewerVideoCell
- (void)sundialVideoPlaybackViewDidStartPlaying:(id)view {
    %orig;
    if (sciIsPausePlayMode()) {
        Ivar ivar = class_getInstanceVariable([self class], "_playPauseMediaIndicator");
        if (ivar) {
            UIView *indicator = object_getIvar(self, ivar);
            if (indicator) indicator.hidden = YES;
        }
        UIView *playView = sciFindPlaybackView(self);
        if (playView) playView.hidden = YES;
    }
}

- (void)videoViewDidUnpause:(id)view {
    %orig;
    if (sciIsPausePlayMode()) {
        Ivar ivar = class_getInstanceVariable([self class], "_playPauseMediaIndicator");
        if (ivar) {
            UIView *indicator = object_getIvar(self, ivar);
            if (indicator) indicator.hidden = YES;
        }
        UIView *playView = sciFindPlaybackView(self);
        if (playView) playView.hidden = YES;
    }
}
%end

// ============ UFI: SYNC DOWNLOAD BUTTON + SETUP KVO ============

%hook IGSundialViewerVerticalUFI
- (void)setAlpha:(CGFloat)alpha {
    %orig;
    UIView *parent = self.superview;
    if (!parent) return;
    UIView *dlBtn = [parent viewWithTag:1337];
    if (dlBtn) dlBtn.alpha = alpha;
    sciSetupKVO(self);
}
%end

// ============ HIDE MUTE SUBVIEW IN PLAYBACK TOGGLE ============
// When pause/play mode is active, hide the mute sub-toggle (top subview)
// and keep only the play/pause button visible.

static void (*orig_playbackToggle_didMoveToSuperview)(id self, SEL _cmd);
static void (*orig_playbackToggle_layoutSubviews)(id self, SEL _cmd);

static void sciHideMuteSubview(UIView *toggleView) {
    if (!sciIsPausePlayMode()) {
        for (UIView *sub in toggleView.subviews) {
            if (sub.tag == 9999) {
                sub.hidden = NO; sub.alpha = 1; sub.userInteractionEnabled = YES; sub.tag = 0;
            }
        }
        return;
    }
    NSArray *subs = toggleView.subviews;
    if (subs.count < 2) return;
    UIView *topView = nil;
    CGFloat minY = CGFLOAT_MAX;
    int visibleCount = 0;
    for (UIView *sub in subs) {
        if (sub.frame.size.width < 1 || sub.frame.size.height < 1) continue;
        visibleCount++;
        if (sub.frame.origin.y < minY) { minY = sub.frame.origin.y; topView = sub; }
    }
    if (topView && visibleCount >= 2) {
        topView.hidden = YES; topView.alpha = 0; topView.userInteractionEnabled = NO; topView.tag = 9999;
    }
}

static void new_playbackToggle_didMoveToSuperview(id self, SEL _cmd) {
    orig_playbackToggle_didMoveToSuperview(self, _cmd);
    sciHideMuteSubview((UIView *)self);
}
static void new_playbackToggle_layoutSubviews(id self, SEL _cmd) {
    orig_playbackToggle_layoutSubviews(self, _cmd);
    sciHideMuteSubview((UIView *)self);
}

// ============ FORCE AUDIO IN REELS TAB ============
// Uses _didTapSoundButton on the section controller — the same code path
// as physically tapping the sound button.

static void sciForceUnmuteCell(id videoCell) {
    if (!videoCell) return;
    Ivar delegateIvar = class_getInstanceVariable([videoCell class], "_delegate");
    if (!delegateIvar) return;
    id sectionCtrl = object_getIvar(videoCell, delegateIvar);
    if (!sectionCtrl) return;
    SEL isAudioSel = NSSelectorFromString(@"isAudioEnabled");
    if (![sectionCtrl respondsToSelector:isAudioSel]) return;
    BOOL audioOn = ((BOOL(*)(id,SEL))objc_msgSend)(sectionCtrl, isAudioSel);
    if (audioOn) return;
    SEL tapSel = NSSelectorFromString(@"_didTapSoundButton");
    if ([sectionCtrl respondsToSelector:tapSel]) {
        ((void(*)(id,SEL))objc_msgSend)(sectionCtrl, tapSel);
    }
}

%hook IGSundialFeedViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sciIsInReelsTab = YES;
    // Force unmute first reel — retry until the cell is ready
    if (sciIsPausePlayMode()) {
        id feedVC = self;
        for (int i = 0; i < 10; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.1 + i * 0.15) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!sciIsInReelsTab) return;
                SEL sel = NSSelectorFromString(@"_currentAudioCell");
                if (![feedVC respondsToSelector:sel]) return;
                id cell = ((id(*)(id,SEL))objc_msgSend)(feedVC, sel);
                if (cell) sciForceUnmuteCell(cell);
            });
        }
    }
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    sciIsInReelsTab = NO;
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    %orig;
    if (sciIsPausePlayMode() && sciIsInReelsTab) {
        SEL sel = NSSelectorFromString(@"_currentAudioCell");
        if ([self respondsToSelector:sel]) {
            id cell = ((id(*)(id,SEL))objc_msgSend)(self, sel);
            if (cell) sciForceUnmuteCell(cell);
        }
    }
}
%end

// ============ RUNTIME HOOKS ============

%ctor {
    Class toggleClass = objc_getClass("IGSundialPlaybackToggle.IGSundialPlaybackToggleView");
    if (toggleClass) {
        MSHookMessageEx(toggleClass, @selector(didMoveToSuperview),
                        (IMP)new_playbackToggle_didMoveToSuperview, (IMP *)&orig_playbackToggle_didMoveToSuperview);
        MSHookMessageEx(toggleClass, @selector(layoutSubviews),
                        (IMP)new_playbackToggle_layoutSubviews, (IMP *)&orig_playbackToggle_layoutSubviews);
    }
}
