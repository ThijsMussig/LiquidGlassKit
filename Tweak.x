/*
 * Tweak.x  –  LiquidGlass
 * Dock + Passcode + Folder icons: SBFloatingDockView (iPad), SBDockView (iPhone),
 * SBUIPasscodeKeypadButton / SBUIPasscodeKeypadDigitButton / CSUIPasscodeKeypadButton,
 * SBFolderIconImageView (home screen folder icon)
 */

#import <UIKit/UIKit.h>

extern void LGApplyToDockView(UIView *view);
extern void LGApplyToPasscodeButton(UIView *view);
extern void LGApplyToFolderIcon(UIView *view);
extern void LGApplyToFolderBackground(UIView *view);
extern void LGHideFolderGlass(UIView *view);
extern void LGApplyToNotificationCell(UIView *view);
extern void LGApplyToMediaPlayer(UIView *view);
extern void LGStripMediaPlayerControls(UIView *view);
extern void LGSetupSwitchOverlay(UISwitch *sw);
extern void LGSyncSwitchOverlay(UISwitch *sw);
extern void LGTeardownSwitchOverlay(UISwitch *sw);
extern void LGSetupSliderOverlay(UISlider *s);
extern void LGSyncSliderOverlay(UISlider *s);
extern void LGTeardownSliderOverlay(UISlider *s);
extern void LGApplyToSearchBar(UIView *view);
extern void LGApplyToSpotlightSearch(UIView *view);
extern void LGApplyToLockQuickAction(UIView *view);
extern void LGApplyToBanner(UIView *view);

// Helper: walk up to `depth` superviews and return YES if any matches `cls`.
static BOOL isInsideClass(UIView *view, NSString *cls, int depth) {
    UIView *p = view;
    for (int i = 0; i < depth && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:cls]) return YES;
    }
    return NO;
}

%group FloatingDock
%hook SBFloatingDockView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToDockView(v);
}
%end
%end

%group Dock
%hook SBDockView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToDockView(v);
}
%end
%end

%group Passcode
%hook SBUIPasscodeKeypadButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToPasscodeButton(v);
}
%end
%end

%group PasscodeDigit
%hook SBUIPasscodeKeypadDigitButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToPasscodeButton(v);
}
%end
%end

%group PasscodeCS
%hook CSUIPasscodeKeypadButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToPasscodeButton(v);
}
%end
%end

// iOS 26: passcode digit buttons became CSPropertyAnimatingTouchPassThroughView.
// Guard: only apply glass when the view is roughly square (it's a circular button, not a keypad
// container). The keypad container is ~375pt wide; each button is ≤ 130pt — use that threshold.
%group PasscodePropertyAnimating
%hook CSPropertyAnimatingTouchPassThroughView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    // Guard: only apply inside a lock-screen/cover-sheet window.
    // CSPropertyAnimatingTouchPassThroughView is also instantiated during home-screen
    // transition animations (icon zoom, lock animation etc.). Matching those views and
    // calling stripButtonMaterial on them while SpringBoard is animating causes an
    // exception in the render server → SpringBoard safe mode.
    NSString *winCls = NSStringFromClass([v.window class]);
    if (![winCls containsString:@"CoverSheet"] && ![winCls containsString:@"LockScreen"]) return;
    CGSize s = v.bounds.size;
    if (s.width > 0 && s.width <= 130 && fabs(s.width - s.height) < 20)
        LGApplyToPasscodeButton(v);
}
%end
%end

// Delete / backspace key on the passcode keypad.
%group PasscodeDelete
%hook SBUIPasscodeDeleteButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToPasscodeButton(v);
}
%end
%end

// Lock screen media player — CSAdjunctItemView is the outer rounded card that wraps the
// Now Playing widget. MPUSystemMediaControlsView is its inner controls container.
// We apply glass to CSAdjunctItemView (the whole card) and strip material from
// MPUSystemMediaControlsView so nothing bleeds through.
//
// Guard: on iOS 26 Apple reused CSAdjunctItemView for lockscreen widgets beyond just the
// media player (e.g. the clock/date capsule). Only apply glass if MPUSystemMediaControlsView
// exists as a descendant — confirming this is actually a Now Playing card.
static BOOL LG_hasMPUControls(UIView *root, int depth) {
    if (depth > 6) return NO;
    static Class mpuCls;
    if (!mpuCls) mpuCls = NSClassFromString(@"MPUSystemMediaControlsView");
    if (mpuCls && [root isKindOfClass:mpuCls]) return YES;
    for (UIView *sub in root.subviews)
        if (LG_hasMPUControls(sub, depth + 1)) return YES;
    return NO;
}

%group MediaPlayer
%hook CSAdjunctItemView
- (void)setBackgroundColor:(UIColor *)color {
    // Force clear — intercepting at ObjC level prevents any code from re-applying background.
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window && LG_hasMPUControls(v, 0)) LGApplyToMediaPlayer(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window && LG_hasMPUControls(v, 0)) LGApplyToMediaPlayer(v);
}
%end
%end

%group MediaPlayerControls
%hook MPUSystemMediaControlsView
// Strip-only — no glass. The outer CSAdjunctItemView owns the single glass layer.
// Adding glass here too creates a visible inner glass card on top of the outer one.
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGStripMediaPlayerControls(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGStripMediaPlayerControls(v);
}
%end
%end

// Home screen banner notifications — NCNotificationShortLookView is the rounded pill that
// slides down from the top of the screen. Use the same .regular glass style as lock screen
// notifications so it adapts its tint colour to light / dark mode automatically.
%group Banner
%hook NCNotificationShortLookView
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
    ((UIView *)self).layer.borderColor = [UIColor clearColor].CGColor;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToBanner(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToBanner(v);
}
%end
%end

// Lock screen notification cells — NCNotificationListCell is the rounded pill per-notification.
// didMoveToWindow: initial setup when cell enters screen.
// layoutSubviews: O(1) frame sync for cells that already have glass; for cells without glass,
// checks the transform — only cells with identity transform (top of stack or expanded) get
// glass created. Peeking stack cards have a scale/translate transform and are skipped until
// the user expands the stack, at which point their transform becomes identity during the
// animation and glass is created lazily.
%group Notification
%hook NCNotificationListCell
- (void)setBackgroundColor:(UIColor *)color {
    // Always force clear — UIKit constantly re-applies the tinted pill colour via direct
    // property set; intercepting here prevents ANY code from setting a background.
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToNotificationCell(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToNotificationCell(v);
}
%end
%end

// UISlider → LiquidGlassSlider overlay
%group Slider
%hook UISlider
- (void)didMoveToSuperview {
    %orig;
    if (((UIView *)self).superview) LGSetupSliderOverlay((UISlider *)self);
}
- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview) LGTeardownSliderOverlay((UISlider *)self);
    %orig;
}
- (void)layoutSubviews {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
// Re-hide native layers on every touch phase — UISlider rebuilds its sublayers
// during tracking, causing the original thumb/track to peek through between layout passes.
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL r = %orig;
    LGSyncSliderOverlay((UISlider *)self);
    return r;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL r = %orig;
    LGSyncSliderOverlay((UISlider *)self);
    return r;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
%end
%end

// UISwitch → LiquidGlassSwitch overlay
%group Switch
%hook UISwitch
- (void)didMoveToSuperview {
    %orig;
    if (((UIView *)self).superview) LGSetupSwitchOverlay((UISwitch *)self);
}
- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview) LGTeardownSwitchOverlay((UISwitch *)self);
    %orig;
}
- (void)layoutSubviews {
    %orig;
    LGSyncSwitchOverlay((UISwitch *)self);
}
- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    LGSyncSwitchOverlay((UISwitch *)self);
}
%end
%end

// Home screen folder icon — SBFolderIconImageView is the 60×60 rounded-rect
// that renders the mini-app grid. Hook layoutSubviews to apply glass each layout pass.
%group FolderIcon
%hook SBFolderIconImageView
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    // Skip folder icons inside App Library pods — handled by ALFolderIcon in LiquidGlassAL.x
    static Class podCls;
    if (!podCls) podCls = NSClassFromString(@"SBHLibraryCategoryPodView");
    if (podCls) { UIView *p = v.superview; while (p) { if ([p isKindOfClass:podCls]) return; p = p.superview; } }
    LGApplyToFolderIcon(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    // Skip folder icons inside App Library pods — handled by ALFolderIcon in LiquidGlassAL.x
    static Class podCls2;
    if (!podCls2) podCls2 = NSClassFromString(@"SBHLibraryCategoryPodView");
    if (podCls2) { UIView *p = v.superview; while (p) { if ([p isKindOfClass:podCls2]) return; p = p.superview; } }
    LGApplyToFolderIcon(v);
}
%end
%end

static void LGKillBackdropsInLayer(CALayer *layer) {
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    for (CALayer *sub in layer.sublayers) {
        if (backdropClass && [sub isKindOfClass:backdropClass]) {
            [sub setValue:@NO forKey:@"enabled"];
            sub.opacity = 0;
        }
        LGKillBackdropsInLayer(sub);
    }
}

// Open folder background — SBFolderBackgroundView holds the blur pill.
// Glass fades in after the open animation; alpha resets to 0 before close.
%group FolderBG
%hook SBFolderBackgroundView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (newWindow) {
        // Folder opening — always hide glass + kill backdrop BEFORE any frame is rendered.
        // This fires before the open animation starts, so the compositor never sees the glass.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (UIView *sub in v.subviews) {
            sub.hidden = YES;
            LGKillBackdropsInLayer(sub.layer);
        }
        [CATransaction commit];
        // LGApplyToFolderBackground will schedule the reveal via deferFolderGlass.
    } else {
        // Folder closing — hide glass and disable backdrop for next open.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (UIView *sub in v.subviews) {
            sub.hidden = YES;
            LGKillBackdropsInLayer(sub.layer);
        }
        [CATransaction commit];
    }
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    // Always re-setup: ensures reveal is scheduled even on view reuse.
    if (v.window) LGApplyToFolderBackground(v);
}
%end
%end

// Kill _UIBackdropView the instant it enters SBFolderBackgroundView or CSAdjunctItemView.
// Only checks 4 levels — these views are always close ancestors.
%group FolderBackdropKiller
%hook _UIBackdropView
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    UIView *p = newSuperview;
    for (int i = 0; i < 4 && p; i++, p = p.superview) {
        NSString *cls = NSStringFromClass([p class]);
        if ([cls isEqualToString:@"SBFolderBackgroundView"] ||
            [cls isEqualToString:@"CSAdjunctItemView"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ((UIView *)self).alpha = 0;
            ((UIView *)self).hidden = YES;
            [((UIView *)self).layer setValue:@NO forKey:@"enabled"];
            [CATransaction commit];
            return;
        }
    }
}
- (void)didMoveToSuperview {
    %orig;
    if (!((UIView *)self).superview) return;
    UIView *p = ((UIView *)self).superview;
    for (int i = 0; i < 4 && p; i++, p = p.superview) {
        NSString *cls = NSStringFromClass([p class]);
        if ([cls isEqualToString:@"SBFolderBackgroundView"] ||
            [cls isEqualToString:@"CSAdjunctItemView"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ((UIView *)self).alpha = 0;
            ((UIView *)self).hidden = YES;
            [((UIView *)self).layer setValue:@NO forKey:@"enabled"];
            [CATransaction commit];
            return;
        }
    }
}
%end
%end

// App Library search bar — SBHSearchTextField is the rounded search field at the top.
%group SearchBar
%hook SBHSearchTextField
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSearchBar(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSearchBar(v);
}
%end
%end

// Home screen Spotlight search pill — SBSearchBarTextField is the search input on the home screen.
%group SpotlightSearch
%hook SBSearchBarTextField
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSpotlightSearch(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSpotlightSearch(v);
}
%end
%end

// Kill MTMaterialView when inside the App Library search bar hierarchy.
// Depth 4: MTMaterialView is always close to SBHSearchTextField or SBSearchBarTextField.
%group SearchBarMaterial
%hook MTMaterialView
// Called every layout pass — fire on the superview if size + window match the quick action circle.
- (void)layoutSubviews {
    %orig;
    UIView *v  = (UIView *)self;
    UIView *sv = v.superview;
    if (!sv || !v.window) return;

    // Suppress in App Library / search bar ancestors (class-name route, depth 4).
    if (isInsideClass(sv, @"SBHSearchTextField", 4) ||
        isInsideClass(sv, @"SBSearchBarTextField", 4)) {
        v.hidden = YES; v.alpha = 0; v.layer.opacity = 0;
        return;
    }

    // Lock screen quick action detection: MTMaterialView is the circle background (≈50×50 pt),
    // lives on a CoverSheet/LockScreen window.
    NSString *winCls = NSStringFromClass([v.window class]);
    BOOL isLockScreen = [winCls containsString:@"CoverSheet"] || [winCls containsString:@"LockScreen"];
    if (!isLockScreen) return;
    CGSize s = v.bounds.size;
    if (s.width < 30 || s.width > 90) return;          // not a quick-action circle
    if (fabs(s.width - s.height) > 15) return;         // must be roughly square

    // Exclude notification swipe-action buttons (PLPlatterActionButton, etc.)
    UIView *p = sv;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"NCNotification"] ||
            [cn containsString:@"PLPlatter"] ||
            [cn containsString:@"ActionButton"] ||
            [cn containsString:@"SwipeAction"] ||
            [cn containsString:@"NotificationList"]) return;
    }

    // Hide the material circle and glass the parent button container.
    v.hidden = YES;
    v.alpha  = 0;
    v.layer.opacity = 0;
    LGApplyToLockQuickAction(sv);
}
// Also hide eagerly when added to a search-bar ancestor.
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    if (isInsideClass(newSuperview, @"SBHSearchTextField", 4) ||
        isInsideClass(newSuperview, @"SBSearchBarTextField", 4)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha  = 0;
        ((UIView *)self).layer.opacity = 0;
    }
}
- (void)didMoveToSuperview {
    %orig;
    UIView *sup = ((UIView *)self).superview;
    if (!sup) return;
    if (isInsideClass(sup, @"SBHSearchTextField", 4) ||
        isInsideClass(sup, @"SBSearchBarTextField", 4)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha  = 0;
        ((UIView *)self).layer.opacity = 0;
    }
}
%end
%end

// UIVisualEffectView — used as the circular blur background for lock screen quick actions
// on some iOS versions. Hide it and glass the parent when size + window match.
%group QuickActionVisualEffect
%hook UIVisualEffectView
- (void)layoutSubviews {
    %orig;
    UIView *v  = (UIView *)self;
    UIView *sv = v.superview;
    if (!sv || !v.window) return;
    NSString *winCls = NSStringFromClass([v.window class]);
    BOOL isLockScreen = [winCls containsString:@"CoverSheet"] || [winCls containsString:@"LockScreen"];
    if (!isLockScreen) return;
    CGSize s = v.bounds.size;
    if (s.width < 30 || s.width > 90) return;
    if (fabs(s.width - s.height) > 15) return;
    // Exclude notification swipe-action buttons — their internal UIVisualEffectView
    // is the same size on the same window, but lives inside NCNotification*,
    // PLPlatterActionButton, UISwipeAction* ancestors.
    UIView *p = sv;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"NCNotification"] ||
            [cn containsString:@"PLPlatter"] ||
            [cn containsString:@"ActionButton"] ||
            [cn containsString:@"SwipeAction"] ||
            [cn containsString:@"NotificationList"]) return;
    }
    v.hidden = YES;
    v.alpha  = 0;
    v.layer.opacity = 0;
    LGApplyToLockQuickAction(sv);
}
%end
%end

// Lock screen quick action buttons — flashlight + camera circular pills.
// Three possible class names depending on iOS version:
//   SBUICallToActionButton  (iOS 14–15)
//   CSCallToActionButton    (iOS 16–17 CoverSheet)
//   SBFunctionButtonView    (iOS 18+)
%group QuickActionSBUI
%hook SBUICallToActionButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToLockQuickAction(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToLockQuickAction(v);
}
%end
%end

%group QuickActionCS
%hook CSCallToActionButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToLockQuickAction(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToLockQuickAction(v);
}
%end
%end

%group QuickActionFunctionButton
%hook SBFunctionButtonView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    // Guard: only on lock screen window, and only small circular buttons (≤ 90 pt)
    NSString *winCls = NSStringFromClass([v.window class]);
    if (![winCls containsString:@"CoverSheet"] && ![winCls containsString:@"LockScreen"]) return;
    CGSize s = v.bounds.size;
    if (s.width > 0 && s.width <= 90 && fabs(s.width - s.height) < 20)
        LGApplyToLockQuickAction(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    NSString *winCls = NSStringFromClass([v.window class]);
    if (![winCls containsString:@"CoverSheet"] && ![winCls containsString:@"LockScreen"]) return;
    CGSize s = v.bounds.size;
    if (s.width > 0 && s.width <= 90 && fabs(s.width - s.height) < 20)
        LGApplyToLockQuickAction(v);
}
%end
%end
%group SearchBarBackground
%hook _UITextFieldRoundedRectBackgroundViewNeue
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    // Walk up to check if we're inside SBHSearchTextField
    UIView *p = newSuperview;
    for (int i = 0; i < 5 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:@"SBHSearchTextField"]) {
            ((UIView *)self).hidden = YES;
            ((UIView *)self).alpha = 0;
            ((UIView *)self).layer.opacity = 0;
            return;
        }
    }
}
- (void)didMoveToSuperview {
    %orig;
    UIView *p = ((UIView *)self).superview;
    for (int i = 0; i < 5 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:@"SBHSearchTextField"]) {
            ((UIView *)self).hidden = YES;
            ((UIView *)self).alpha = 0;
            ((UIView *)self).layer.opacity = 0;
            return;
        }
    }
}
%end
%end

%ctor {
    Class c1 = NSClassFromString(@"SBFloatingDockView");
    if (c1) %init(FloatingDock, SBFloatingDockView = c1);

    Class c2 = NSClassFromString(@"SBDockView");
    if (c2) %init(Dock, SBDockView = c2);

    Class c3 = NSClassFromString(@"SBUIPasscodeKeypadButton");
    if (c3) %init(Passcode, SBUIPasscodeKeypadButton = c3);

    Class c4 = NSClassFromString(@"SBUIPasscodeKeypadDigitButton");
    if (c4) %init(PasscodeDigit, SBUIPasscodeKeypadDigitButton = c4);

    Class c5 = NSClassFromString(@"CSUIPasscodeKeypadButton");
    if (c5) %init(PasscodeCS, CSUIPasscodeKeypadButton = c5);

    Class c5b = NSClassFromString(@"CSPropertyAnimatingTouchPassThroughView");
    if (c5b) %init(PasscodePropertyAnimating, CSPropertyAnimatingTouchPassThroughView = c5b);

    Class c5c = NSClassFromString(@"SBUIPasscodeDeleteButton");
    if (c5c) %init(PasscodeDelete, SBUIPasscodeDeleteButton = c5c);

    Class c6 = NSClassFromString(@"SBFolderIconImageView");
    if (c6) %init(FolderIcon, SBFolderIconImageView = c6);

    Class c7 = NSClassFromString(@"SBFolderBackgroundView");
    if (c7) %init(FolderBG, SBFolderBackgroundView = c7);

    Class c8 = NSClassFromString(@"_UIBackdropView");
    if (c8) %init(FolderBackdropKiller, _UIBackdropView = c8);

    Class cBanner = NSClassFromString(@"NCNotificationShortLookView");
    if (cBanner) %init(Banner, NCNotificationShortLookView = cBanner);

    Class c9 = NSClassFromString(@"NCNotificationListCell");
    if (c9) %init(Notification, NCNotificationListCell = c9);

    Class c10 = NSClassFromString(@"CSAdjunctItemView");
    if (c10) %init(MediaPlayer, CSAdjunctItemView = c10);

    Class c11 = NSClassFromString(@"MPUSystemMediaControlsView");
    if (c11) %init(MediaPlayerControls, MPUSystemMediaControlsView = c11);

    // UISlider and UISwitch are public UIKit classes — always available
    %init(Slider);
    %init(Switch);

    Class c12 = NSClassFromString(@"SBHSearchTextField");
    if (c12) %init(SearchBar, SBHSearchTextField = c12);

    Class c12b = NSClassFromString(@"SBSearchBarTextField");
    if (c12b) %init(SpotlightSearch, SBSearchBarTextField = c12b);

    Class c13 = NSClassFromString(@"_UITextFieldRoundedRectBackgroundViewNeue");
    if (c13) %init(SearchBarBackground, _UITextFieldRoundedRectBackgroundViewNeue = c13);

    Class c14 = NSClassFromString(@"MTMaterialView");
    if (c14) %init(SearchBarMaterial, MTMaterialView = c14);

    %init(QuickActionVisualEffect);

    Class c19 = NSClassFromString(@"SBUICallToActionButton");
    if (c19) %init(QuickActionSBUI, SBUICallToActionButton = c19);

    Class c20 = NSClassFromString(@"CSCallToActionButton");
    if (c20) %init(QuickActionCS, CSCallToActionButton = c20);

    Class c21 = NSClassFromString(@"SBFunctionButtonView");
    if (c21) %init(QuickActionFunctionButton, SBFunctionButtonView = c21);
}

