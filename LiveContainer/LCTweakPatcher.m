@import Darwin;
@import Foundation;
@import MachO;
#import "LCMachOUtils.h"
#include <machine/byte_order.h>

#pragma mark - Tweak Substrate Patching

// List of bad paths that need to be replaced with @loader_path
static const char * const BAD_SUBSTRATE_PATHS[] = {
    "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
    "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
    "/usr/lib/libsubstrate.dylib",
    "/usr/lib/libhooker.dylib",
    "/usr/local/lib/libellekit.dylib",
    NULL
};

static const char *GOOD_SUBSTRATE_PATH = "@loader_path/CydiaSubstrate.framework/CydiaSubstrate";

// Helper function to check if string matches bad paths
static BOOL isSubstratePath(const char *path) {
    if (!path) return NO;
    for (int i = 0; BAD_SUBSTRATE_PATHS[i] != NULL; i++) {
        if (strcmp(path, BAD_SUBSTRATE_PATHS[i]) == 0) {
            return YES;
        }
    }
    return NO;
}

// Patch a single Mach-O slice
static BOOL patchMachOSlice(uint8_t *slicePtr, size_t sliceSize) {
    if (sliceSize < sizeof(struct mach_header_64)) {
        return NO;
    }
    
    struct mach_header_64 *header = (struct mach_header_64 *)slicePtr;
    if (header->magic != MH_MAGIC_64) {
        return NO;
    }
    
    BOOL modified = NO;
    uint8_t *cmdPtr = slicePtr + sizeof(struct mach_header_64);
    uint32_t ncmds = header->ncmds;
    
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *cmd = (struct load_command *)cmdPtr;
        uint32_t cmdsize = cmd->cmdsize;
        
        if (cmdsize < sizeof(struct load_command) || cmdsize > sliceSize) {
            break;
        }
        
        // Check for LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB
        if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB || cmd->cmd == 0x8000001F) {
            struct dylib_command *dylibCmd = (struct dylib_command *)cmd;
            uint32_t nameOffset = dylibCmd->dylib.name.offset;
            
            if (nameOffset < cmdsize && nameOffset < 256) {
                char *dylibName = (char *)cmdPtr + nameOffset;
                size_t availableSpace = cmdsize - nameOffset;
                
                if (isSubstratePath(dylibName)) {
                    size_t goodPathLen = strlen(GOOD_SUBSTRATE_PATH);
                    
                    if (goodPathLen < availableSpace) {
                        // Clear the space and copy new path
                        memset(dylibName, 0, availableSpace);
                        memcpy(dylibName, GOOD_SUBSTRATE_PATH, goodPathLen);
                        modified = YES;
                        NSLog(@"[LC] Patched tweak dylib reference: %s → @loader_path/...", dylibName);
                    }
                }
            }
        }
        
        cmdPtr += cmdsize;
    }
    
    return modified;
}

BOOL LCPatchTweakSubstrateLoad(const char *dylibPath) {
    if (!dylibPath) {
        NSLog(@"[LC] Error: dylibPath is NULL");
        return NO;
    }
    
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:[NSString stringWithUTF8String:dylibPath]];
    if (!data) {
        NSLog(@"[LC] Error: Could not read dylib file: %s", dylibPath);
        return NO;
    }
    
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    size_t length = data.length;
    
    if (length < sizeof(uint32_t)) {
        NSLog(@"[LC] Error: File too small to be Mach-O");
        return NO;
    }
    
    BOOL modified = NO;
    uint32_t magic = *(uint32_t *)bytes;
    
    // Handle Mach-O (64-bit only)
    if (magic == MH_MAGIC_64) {
        modified = patchMachOSlice(bytes, length);
    }
    // Handle Fat binary
    else if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header *fatHeader = (struct fat_header *)bytes;
        uint32_t nfat_arch = OSSwapBigToHostInt32(fatHeader->nfat_arch);
        
        struct fat_arch *arch = (struct fat_arch *)(bytes + sizeof(struct fat_header));
        
        for (uint32_t i = 0; i < nfat_arch; i++) {
            uint32_t offset = OSSwapBigToHostInt32(arch[i].offset);
            uint32_t size = OSSwapBigToHostInt32(arch[i].size);
            
            if (offset + size <= length) {
                if (patchMachOSlice(bytes + offset, size)) {
                    modified = YES;
                }
            }
        }
    }
    
    if (modified) {
        NSError *error = nil;
        if ([data writeToFile:[NSString stringWithUTF8String:dylibPath] 
                  atomically:YES 
                      error:&error]) {
            NSLog(@"[LC] Successfully patched tweak: %s", dylibPath);
            return YES;
        } else {
            NSLog(@"[LC] Error writing patched dylib: %@", error.localizedDescription);
            return NO;
        }
    }
    
    return YES;
}

#pragma mark - DEB Extraction

// AR archive header format
typedef struct {
    char ar_fmag[8];  // "!<arch>\n"
} ar_archive_header_t;

typedef struct {
    char ar_name[16];
    char ar_date[12];
    char ar_uid[6];
    char ar_gid[6];
    char ar_mode[8];
    char ar_size[10];
    char ar_fmag[2];  // "`\n"
} ar_entry_header_t;

// Find data archive in deb and extract it
static BOOL extractDebData(NSData *debData, NSData **outData, NSError **error) {
    if (debData.length < 8) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCTweakPatcher" code:1 
                                    userInfo:@{NSLocalizedDescriptionKey: @"DEB file too small"}];
        }
        return NO;
    }
    
    const char *bytes = (const char *)debData.bytes;
    
    // Check AR magic
    if (strncmp(bytes, "!<arch>\n", 8) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCTweakPatcher" code:2
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid AR archive header"}];
        }
        return NO;
    }
    
    size_t offset = 8;
    
    while (offset + sizeof(ar_entry_header_t) <= debData.length) {
        ar_entry_header_t *entry = (ar_entry_header_t *)(bytes + offset);
        
        // Parse size (10 ASCII digits)
        char sizeStr[11] = {0};
        memcpy(sizeStr, entry->ar_size, 10);
        size_t fileSize = strtoul(sizeStr, NULL, 10);
        
        offset += sizeof(ar_entry_header_t);
        
        // Check for data.tar.gz or data.tar.bz2, etc.
        if (strncmp(entry->ar_name, "data.tar", 8) == 0) {
            if (offset + fileSize <= debData.length) {
                *outData = [NSData dataWithBytes:(bytes + offset) length:fileSize];
                return YES;
            }
        }
        
        // Move to next entry (padded to even offset)
        offset += fileSize;
        if (offset % 2) offset++;
    }
    
    if (error) {
        *error = [NSError errorWithDomain:@"LCTweakPatcher" code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"data.tar not found in DEB"}];
    }
    return NO;
}

BOOL LCExtractDebPackage(const char *debPath, const char *destinationPath, NSError **error) {
    if (!debPath || !destinationPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCTweakPatcher" code:4
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid path parameters"}];
        }
        return NO;
    }
    
    NSData *debData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:debPath]];
    if (!debData) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCTweakPatcher" code:5
                                    userInfo:@{NSLocalizedDescriptionKey: @"Could not read DEB file"}];
        }
        return NO;
    }
    
    NSData *dataArchive = nil;
    if (!extractDebData(debData, &dataArchive, error)) {
        return NO;
    }
    
    // For now, we store the data archive and it will be extracted by higher-level code
    // that has access to compression libraries (zlib, bzip2, etc.)
    NSString *destDir = [NSString stringWithUTF8String:destinationPath];
    NSString *dataArchivePath = [destDir stringByAppendingPathComponent:@"data.tar.gz"];
    
    if (![dataArchive writeToFile:dataArchivePath atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCTweakPatcher" code:6
                                    userInfo:@{NSLocalizedDescriptionKey: @"Could not write extracted data archive"}];
        }
        return NO;
    }
    
    NSLog(@"[LC] Extracted DEB data archive to: %@", dataArchivePath);
    return YES;
}

#pragma mark - CydiaSubstrate Framework Management

BOOL LCCopyCydiaSubstrateFramework(const char *destinationPath) {
    if (!destinationPath) {
        return NO;
    }
    
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSURL *substrateSrc = [mainBundle URLForResource:@"CydiaSubstrate" 
                                           withExtension:@"framework"];
    
    if (!substrateSrc) {
        NSLog(@"[LC] Warning: CydiaSubstrate.framework not found in main bundle");
        return NO;
    }
    
    NSString *dest = [[NSString stringWithUTF8String:destinationPath] 
                      stringByAppendingPathComponent:@"CydiaSubstrate.framework"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // Remove if exists
    if ([fm fileExistsAtPath:dest]) {
        if (![fm removeItemAtPath:dest error:&error]) {
            NSLog(@"[LC] Warning: Could not remove existing framework: %@", error);
        }
    }
    
    if ([fm copyItemAtURL:substrateSrc toURL:[NSURL fileURLWithPath:dest] error:&error]) {
        NSLog(@"[LC] Copied CydiaSubstrate.framework to: %s", destinationPath);
        return YES;
    } else {
        NSLog(@"[LC] Error copying CydiaSubstrate.framework: %@", error);
        return NO;
    }
}
