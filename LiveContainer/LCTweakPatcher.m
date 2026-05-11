#import "LCTweakPatcher.h"
@import Foundation;
@import MachO;
#import <string.h>
#import <libkern/OSByteOrder.h>

// Substrate/ElleKit paths that need to be patched
static const char *kBadSubstratePaths[] = {
    "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libhooker.dylib",
    "/usr/local/lib/libellekit.dylib",
    NULL
};

static const char *kGoodSubstratePath = "@loader_path/CydiaSubstrate.framework/CydiaSubstrate";

#pragma mark - Helper Functions

static NSArray<NSNumber *> *_getMachOSliceOffsets(const uint8_t *data, NSUInteger length) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    if (length < 4) return offsets;
    
    uint32_t magic = *(uint32_t *)data;
    
    // Single Mach-O
    if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        [offsets addObject:@0];
        return offsets;
    }
    
    // Fat binary (universal binary)
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        BOOL swap = (magic == FAT_CIGAM);
        struct fat_header *fh = (struct fat_header *)data;
        uint32_t nfat_arch = swap ? OSSwapInt32(fh->nfat_arch) : fh->nfat_arch;
        
        struct fat_arch *archs = (struct fat_arch *)(fh + 1);
        for (uint32_t i = 0; i < nfat_arch; i++) {
            uint32_t offset = swap ? OSSwapInt32(archs[i].offset) : archs[i].offset;
            if (offset < length) {
                [offsets addObject:@(offset)];
            }
        }
    }
    
    return offsets;
}

static BOOL _patchMachOSlice(uint8_t *sliceData, NSUInteger sliceSize, const char *goodPath, size_t goodLen) {
    if (sliceSize < sizeof(struct mach_header_64)) return NO;
    
    struct mach_header_64 *header = (struct mach_header_64 *)sliceData;
    
    // Validate magic
    if (header->magic != MH_MAGIC_64 && header->magic != MH_MAGIC) {
        return NO;
    }
    
    BOOL modified = NO;
    uint32_t headerSize = (header->magic == MH_MAGIC_64) ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    
    struct load_command *cmd = (struct load_command *)(sliceData + headerSize);
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((uint8_t *)cmd + sizeof(struct load_command) > sliceData + sliceSize) break;
        if (cmd->cmdsize == 0 || cmd->cmdsize > sliceSize) break;
        
        // Check for LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB
        if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB || cmd->cmd == LC_REEXPORT_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)cmd;
            
            if (dylib->dylib.name.offset < cmd->cmdsize) {
                char *dylibPath = (char *)dylib + dylib->dylib.name.offset;
                size_t available = cmd->cmdsize - dylib->dylib.name.offset;
                
                // Check if this is a bad substrate path
                for (int j = 0; kBadSubstratePaths[j] != NULL; j++) {
                    if (strcmp(dylibPath, kBadSubstratePaths[j]) == 0) {
                        // Verify we have enough space
                        if (goodLen < available) {
                            memset(dylibPath, 0, available);
                            memcpy(dylibPath, goodPath, goodLen);
                            modified = YES;
                            NSLog(@"[LC] Patched: %s → %s", kBadSubstratePaths[j], goodPath);
                        } else {
                            NSLog(@"[LC] ERROR: Not enough space to patch %s (need %zu, have %zu)", 
                                  kBadSubstratePaths[j], goodLen, available);
                        }
                        break;
                    }
                }
            }
        }
        
        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }
    
    return modified;
}

static BOOL _patchLCIDSlice(uint8_t *sliceData, NSUInteger sliceSize, const char *newID, size_t newIDLen) {
    if (sliceSize < sizeof(struct mach_header_64)) return NO;
    
    struct mach_header_64 *header = (struct mach_header_64 *)sliceData;
    
    if (header->magic != MH_MAGIC_64 && header->magic != MH_MAGIC) {
        return NO;
    }
    
    BOOL modified = NO;
    uint32_t headerSize = (header->magic == MH_MAGIC_64) ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    
    struct load_command *cmd = (struct load_command *)(sliceData + headerSize);
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((uint8_t *)cmd + sizeof(struct load_command) > sliceData + sliceSize) break;
        if (cmd->cmdsize == 0 || cmd->cmdsize > sliceSize) break;
        
        if (cmd->cmd == LC_ID_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)cmd;
            
            if (dylib->dylib.name.offset < cmd->cmdsize) {
                char *currentID = (char *)dylib + dylib->dylib.name.offset;
                size_t available = cmd->cmdsize - dylib->dylib.name.offset;
                
                // Only patch if it's one of the bad ElleKit IDs
                if (strcmp(currentID, "/usr/local/lib/libellekit.dylib") == 0) {
                    if (newIDLen < available) {
                        memset(currentID, 0, available);
                        memcpy(currentID, newID, newIDLen);
                        modified = YES;
                        NSLog(@"[LC] Patched LC_ID: /usr/local/lib/libellekit.dylib → %s", newID);
                    }
                }
            }
        }
        
        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }
    
    return modified;
}

#pragma mark - Public API

@implementation LCTweakPatcher

+ (BOOL)patchTweakMachOSubstrateReferences:(NSString *)dylibPath {
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:dylibPath];
    if (!data) {
        NSLog(@"[LC] Failed to read dylib: %@", dylibPath);
        return NO;
    }
    
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger length = data.length;
    BOOL modified = NO;
    
    // Get slice offsets (handles fat binaries)
    NSArray<NSNumber *> *sliceOffsets = _getMachOSliceOffsets(bytes, length);
    
    size_t goodLen = strlen(kGoodSubstratePath);
    
    for (NSNumber *offsetNum in sliceOffsets) {
        NSUInteger offset = offsetNum.unsignedIntegerValue;
        if (offset >= length) continue;
        
        uint8_t *sliceData = bytes + offset;
        NSUInteger sliceSize = length - offset;
        
        if (_patchMachOSlice(sliceData, sliceSize, kGoodSubstratePath, goodLen)) {
            modified = YES;
        }
    }
    
    if (modified) {
        if (![data writeToFile:dylibPath atomically:YES]) {
            NSLog(@"[LC] Failed to write patched dylib: %@", dylibPath);
            return NO;
        }
        NSLog(@"[LC] Successfully patched: %@", dylibPath);
    }
    
    return modified;
}

+ (BOOL)patchDylibLCID:(NSString *)dylibPath newID:(NSString *)newID {
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:dylibPath];
    if (!data) {
        NSLog(@"[LC] Failed to read dylib: %@", dylibPath);
        return NO;
    }
    
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger length = data.length;
    BOOL modified = NO;
    
    NSArray<NSNumber *> *sliceOffsets = _getMachOSliceOffsets(bytes, length);
    
    const char *newIDCStr = newID.UTF8String;
    size_t newIDLen = strlen(newIDCStr);
    
    for (NSNumber *offsetNum in sliceOffsets) {
        NSUInteger offset = offsetNum.unsignedIntegerValue;
        if (offset >= length) continue;
        
        uint8_t *sliceData = bytes + offset;
        NSUInteger sliceSize = length - offset;
        
        if (_patchLCIDSlice(sliceData, sliceSize, newIDCStr, newIDLen)) {
            modified = YES;
        }
    }
    
    if (modified) {
        if (![data writeToFile:dylibPath atomically:YES]) {
            NSLog(@"[LC] Failed to write patched dylib: %@", dylibPath);
            return NO;
        }
        NSLog(@"[LC] Successfully patched LC_ID in: %@", dylibPath);
    }
    
    return modified;
}

+ (BOOL)hasSubstrateDependencies:(NSString *)dylibPath {
    NSData *data = [NSData dataWithContentsOfFile:dylibPath];
    if (!data) return NO;
    
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    
    NSArray<NSNumber *> *sliceOffsets = _getMachOSliceOffsets(bytes, length);
    
    for (NSNumber *offsetNum in sliceOffsets) {
        NSUInteger offset = offsetNum.unsignedIntegerValue;
        if (offset >= length) continue;
        
        const uint8_t *sliceData = bytes + offset;
        NSUInteger sliceSize = length - offset;
        
        if (sliceSize < sizeof(struct mach_header_64)) continue;
        
        const struct mach_header_64 *header = (const struct mach_header_64 *)sliceData;
        if (header->magic != MH_MAGIC_64 && header->magic != MH_MAGIC) continue;
        
        uint32_t headerSize = (header->magic == MH_MAGIC_64) ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
        
        const struct load_command *cmd = (const struct load_command *)(sliceData + headerSize);
        
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if ((sliceData + sliceSize) - (const uint8_t *)cmd < (int)sizeof(struct load_command)) break;
            if (cmd->cmdsize == 0 || cmd->cmdsize > sliceSize) break;
            
            if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB || cmd->cmd == LC_REEXPORT_DYLIB) {
                const struct dylib_command *dylib = (const struct dylib_command *)cmd;
                
                if (dylib->dylib.name.offset < cmd->cmdsize) {
                    const char *dylibPath = (const char *)dylib + dylib->dylib.name.offset;
                    
                    for (int j = 0; kBadSubstratePaths[j] != NULL; j++) {
                        if (strcmp(dylibPath, kBadSubstratePaths[j]) == 0) {
                            return YES;
                        }
                    }
                }
            }
            
            cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
        }
    }
    
    return NO;
}

+ (NSArray<NSString *> *)loadedDylibsOfMachO:(NSString *)dylibPath {
    NSMutableArray<NSString *> *dylibs = [NSMutableArray array];
    
    NSData *data = [NSData dataWithContentsOfFile:dylibPath];
    if (!data) return dylibs;
    
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    
    NSArray<NSNumber *> *sliceOffsets = _getMachOSliceOffsets(bytes, length);
    
    for (NSNumber *offsetNum in sliceOffsets) {
        NSUInteger offset = offsetNum.unsignedIntegerValue;
        if (offset >= length) continue;
        
        const uint8_t *sliceData = bytes + offset;
        NSUInteger sliceSize = length - offset;
        
        if (sliceSize < sizeof(struct mach_header_64)) continue;
        
        const struct mach_header_64 *header = (const struct mach_header_64 *)sliceData;
        if (header->magic != MH_MAGIC_64 && header->magic != MH_MAGIC) continue;
        
        uint32_t headerSize = (header->magic == MH_MAGIC_64) ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
        
        const struct load_command *cmd = (const struct load_command *)(sliceData + headerSize);
        
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if ((sliceData + sliceSize) - (const uint8_t *)cmd < (int)sizeof(struct load_command)) break;
            if (cmd->cmdsize == 0 || cmd->cmdsize > sliceSize) break;
            
            if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB || cmd->cmd == LC_REEXPORT_DYLIB) {
                const struct dylib_command *dylib = (const struct dylib_command *)cmd;
                
                if (dylib->dylib.name.offset < cmd->cmdsize) {
                    const char *path = (const char *)dylib + dylib->dylib.name.offset;
                    NSString *pathStr = @(path);
                    if (pathStr && ![dylibs containsObject:pathStr]) {
                        [dylibs addObject:pathStr];
                    }
                }
            }
            
            cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
        }
    }
    
    return dylibs;
}

@end
