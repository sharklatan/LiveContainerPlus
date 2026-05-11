#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCTweakPatcher : NSObject

/**
 * Patches all LC_LOAD_DYLIB commands in a Mach-O dylib that reference
 * Substrate/ElleKit with incorrect paths (absolute or @executable_path).
 * Rewrites them to use @loader_path for relative loading.
 *
 * @param dylibPath Path to the .dylib file to patch
 * @return YES if the file was modified, NO otherwise
 */
+ (BOOL)patchTweakMachOSubstrateReferences:(NSString *)dylibPath;

/**
 * Patches the LC_ID_DYLIB command of a dylib (typically ElleKit).
 * Changes the identity from incorrect system paths to correct framework paths.
 *
 * @param dylibPath Path to the dylib
 * @param newID The new LC_ID to set (e.g., "@rpath/CydiaSubstrate.framework/CydiaSubstrate")
 * @return YES if patched successfully, NO otherwise
 */
+ (BOOL)patchDylibLCID:(NSString *)dylibPath newID:(NSString *)newID;

/**
 * Checks if a dylib has any Substrate/ElleKit dependencies that need patching.
 *
 * @param dylibPath Path to the dylib
 * @return YES if substrate references found, NO otherwise
 */
+ (BOOL)hasSubstrateDependencies:(NSString *)dylibPath;

/**
 * Gets all LC_LOAD_DYLIB paths from a dylib.
 *
 * @param dylibPath Path to the dylib
 * @return Array of NSString paths, or empty array if none found
 */
+ (NSArray<NSString *> *)loadedDylibsOfMachO:(NSString *)dylibPath;

NS_ASSUME_NONNULL_END
