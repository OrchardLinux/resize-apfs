// Resize APFS inside the Dopamine app (scripts/embed.py adds this library to its executable).
//
// Dopamine's own interface is never shown: scripts/embed.py takes its scene configuration out
// of Info.plist, so its app delegate makes no window, and this library puts up the Resize APFS
// window once the app has launched. The app's Swift side (App/StorageAccess.swift) reaches
// Dopamine only through RAFAccessBridge below, which calls only what DopamineInterface.h lists.
#import <UIKit/UIKit.h>
#import "DopamineInterface.h"

@interface RAFAccessBridge : NSObject
@end

@implementation RAFAccessBridge

static DOEnvironmentManager *environment(void) {
    return [NSClassFromString(@"DOEnvironmentManager") sharedManager];
}

/// Storage access is there: the helper can be started and reached.
- (BOOL)isReady {
    return [environment() isJailbroken];
}

/// The home screen must restart once before access can be obtained (older devices).
- (BOOL)needsScreenRestart {
    return [[NSClassFromString(@"DOJailbreaker") new] contiguousMappingWorkaroundNeeded];
}

- (void)restartScreen {
    [[NSClassFromString(@"DOJailbreaker") new] applyContiguousMappingWorkaround];
}

/// Obtains access. nil on success: then `prepare` ran (as root, outside the sandbox) and the
/// caller calls `finish`. Blocks for the whole run; call it off the main thread.
- (NSString *)obtain:(void (^)(void))prepare {
    DOJailbreaker *jailbreaker = [NSClassFromString(@"DOJailbreaker") new];
    if (!jailbreaker || !environment()) return @"This copy of the app lacks its access component.";
    NSError *error = nil;
    BOOL removed = NO, logs = YES;
    // The setup script of the files Dopamine unpacks on a device's first run (Procursus's
    // prep_bootstrap.sh) asks the user to set a terminal password unless this is set, as
    // Dopamine's own later runs set it. Nothing here uses a terminal or a password.
    setenv("NO_PASSWORD_PROMPT", "1", 1);
    @try {
        // Without this, the run draws Dopamine's logo for the screen restart.
        [[NSClassFromString(@"DOPreferenceManager") sharedManager] setPreferenceValue:@NO forKey:@"bootlogoEnabled"];
        [jailbreaker runWithError:&error didRemoveJailbreak:&removed showLogs:&logs];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
    }
    if (error) return error.localizedDescription ?: @"Unknown error.";
    if (removed) return @"Access was removed instead of obtained.";
    [self privileged:prepare];
    return nil;
}

/// Restarts the screen to complete access; the app ends with it.
- (void)finish {
    [[NSClassFromString(@"DOJailbreaker") new] finalize];
}

/// Runs `block` as root and outside the app sandbox, when access is there.
- (void)privileged:(void (^)(void))block {
    DOEnvironmentManager *manager = environment();
    [manager runAsRoot:^{ [manager runUnsandboxed:block]; }];
}

@end

__attribute__((constructor)) static void RAFAccessLoad(void) {
    // Dopamine's own maintenance commands (it starts itself with arguments) end before the
    // app launches, so this never runs for them.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        Class app = NSClassFromString(@"RAFEmbeddedApp");
        SEL start = NSSelectorFromString(@"startWithBridge:");
        if ([app respondsToSelector:start]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [app performSelector:start withObject:[RAFAccessBridge new]];
            #pragma clang diagnostic pop
        }
    }];
}
