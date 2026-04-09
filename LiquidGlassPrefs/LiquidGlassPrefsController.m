#import <Preferences/PSListController.h>
#import <spawn.h>

extern char **environ;

@interface LiquidGlassPrefsController : PSListController
@end

@implementation LiquidGlassPrefsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)respring {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char **)args, environ);
}

@end
