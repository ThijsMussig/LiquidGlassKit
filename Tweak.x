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

// Lock screen media player — CSAdjunctItemView is the outer rounded card that wraps the
// Now Playing widget. MPUSystemMediaControlsView is its inner controls container.
// We apply glass to CSAdjunctItemView (the whole card) and strip material from
// MPUSystemMediaControlsView so nothing bleeds through.
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
    if (v.window) LGApplyToMediaPlayer(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToMediaPlayer(v);
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
    if (v.window) LGApplyToFolderIcon(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToFolderIcon(v);
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

// Kill _UIBackdropView the instant it enters SBFolderBackgroundView — before any render.
// willMoveToSuperview: fires synchronously before the layer tree is updated.
%group FolderBackdropKiller
%hook _UIBackdropView
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    // Walk up to 8 levels to find SBFolderBackgroundView or CSAdjunctItemView
    UIView *p = newSuperview;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
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
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
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

    Class c6 = NSClassFromString(@"SBFolderIconImageView");
    if (c6) %init(FolderIcon, SBFolderIconImageView = c6);

    Class c7 = NSClassFromString(@"SBFolderBackgroundView");
    if (c7) %init(FolderBG, SBFolderBackgroundView = c7);

    Class c8 = NSClassFromString(@"_UIBackdropView");
    if (c8) %init(FolderBackdropKiller, _UIBackdropView = c8);

    Class c9 = NSClassFromString(@"NCNotificationListCell");
    if (c9) %init(Notification, NCNotificationListCell = c9);

    Class c10 = NSClassFromString(@"CSAdjunctItemView");
    if (c10) %init(MediaPlayer, CSAdjunctItemView = c10);

    Class c11 = NSClassFromString(@"MPUSystemMediaControlsView");
    if (c11) %init(MediaPlayerControls, MPUSystemMediaControlsView = c11);

    // UISlider and UISwitch are public UIKit classes — always available
    %init(Slider);
    %init(Switch);
}

