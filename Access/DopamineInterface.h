// Everything Resize APFS uses from the Dopamine app it is loaded into: three classes, eight
// methods and one setting, declared as Dopamine 3.0.13 declares them (Application/Dopamine/
// Jailbreak/DOJailbreaker.h, DOEnvironmentManager.h and DOPreferenceManager.h). Nothing else of Dopamine is called.
//
// The classes are looked up by name at run time, so this file needs no Dopamine source. When
// the pinned Dopamine changes (scripts/tools.py), scripts/embed.py refuses a release whose
// executable lacks one of these names (INTERFACE there lists the same ones).
#import <Foundation/Foundation.h>

@interface DOJailbreaker : NSObject
// A8 and some A9 devices: the exploit first needs the home screen restarted once.
- (BOOL)contiguousMappingWorkaroundNeeded;
- (void)applyContiguousMappingWorkaround;
// The whole run up to, not including, the restart of the screen. Blocks; any thread but main.
- (void)runWithError:(NSError **)errOut didRemoveJailbreak:(BOOL *)didRemove showLogs:(BOOL *)showLogs;
// Restarts the screen (a userspace reboot); the app does not survive it.
- (void)finalize;
@end

@interface DOEnvironmentManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)isJailbroken;
// Run a block as root, and outside the app sandbox. Both end with the block.
- (void)runAsRoot:(void (^)(void))rootBlock;
- (void)runUnsandboxed:(void (^)(void))unsandboxBlock;
@end

@interface DOPreferenceManager : NSObject
+ (instancetype)sharedManager;
// The one setting used: "bootlogoEnabled" = NO, so the screen restart shows no Dopamine logo.
- (void)setPreferenceValue:(NSObject *)obj forKey:(NSString *)key;
@end
