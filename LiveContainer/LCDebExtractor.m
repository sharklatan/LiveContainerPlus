#import "LCDebExtractor.h"
@import Foundation;
#import <zlib.h>
#import <string.h>

#pragma mark - LCExtractedDylib Implementation

@implementation LCExtractedDylib
@end

#pragma mark - Helper Structures & Constants

// ar archive format constants
#define AR_HEADER_MAGIC "!<arch>\n"
#define AR_HEADER_SIZE 8
#define AR_ENTRY_SIZE 60

// tar format constants
#define TAR_HEADER_SIZE 512
#define TAR_NAME_SIZE 100
#define TAR_MODE_SIZE 8
#define TAR_UID_SIZE 8
#define TAR_GID_SIZE 8
#define TAR_SIZE_SIZE 12
#define TAR_MTIME_SIZE 12
#define TAR_CHECKSUM_SIZE 8
#define TAR_TYPEFLAG_OFFSET 156
#define TAR_NAME_OFFSET 0

// tar type flags
#define TAR_REGTYPE '0'
#define TAR_AREGTYPE '\0'

#pragma mark - Helper Functions

static NSString *_trimArString(const char *str, size_t len) {
    // ar entries have fields padded with spaces, trim them
    NSString *result = [[NSString alloc] initWithBytes:str length:len encoding:NSASCIIStringEncoding];
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSUInteger _parseTarSize(const char *sizeField, size_t fieldSize) {
    // tar size is octal ASCII
    char buffer[fieldSize + 1];
    memcpy(buffer, sizeField, fieldSize);
    buffer[fieldSize] = '\0';
    return strtol(buffer, NULL, 8);
}

static BOOL _checkTarChecksum(const uint8_t *header) {
    // tar checksum verification: sum of unsigned bytes, with checksum field treated as spaces
    uint32_t checksum = 0;
    for (int i = 0; i < TAR_HEADER_SIZE; i++) {
        if (i >= 148 && i < 156) {
            checksum += ' ';  // checksum field is spaces
        } else {
            checksum += header[i];
        }
    }
    
    char checksumField[TAR_CHECKSUM_SIZE + 1];
    memcpy(checksumField, header + 148, TAR_CHECKSUM_SIZE);
    checksumField[TAR_CHECKSUM_SIZE] = '\0';
    uint32_t expectedChecksum = (uint32_t)strtol(checksumField, NULL, 8);
    
    return checksum == expectedChecksum;
}

static NSString *_getTarFileName(const uint8_t *header) {
    char nameBuffer[TAR_NAME_SIZE + 1];
    memcpy(nameBuffer, header + TAR_NAME_OFFSET, TAR_NAME_SIZE);
    nameBuffer[TAR_NAME_SIZE] = '\0';
    
    NSString *name = [NSString stringWithUTF8String:nameBuffer];
    if (!name) return nil;
    
    // Remove leading path components like "./" or "/"
    while ([name hasPrefix:@"./"]) {
        name = [name substringFromIndex:2];
    }
    while ([name hasPrefix:@"/"]) {
        name = [name substringFromIndex:1];
    }
    
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSData *_decompressGzip(NSData *compressedData) {
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;
    stream.avail_in = (uint)compressedData.length;
    stream.next_in = (uint8_t *)compressedData.bytes;
    
    // Use wbits | 16 for gzip format
    if (inflateInit2(&stream, 15 | 16) != Z_OK) {
        NSLog(@"[LC] Failed to initialize zlib decompressor");
        return nil;
    }
    
    NSMutableData *decompressed = [NSMutableData data];
    uint8_t buffer[65536];
    int ret;
    
    do {
        stream.avail_out = sizeof(buffer);
        stream.next_out = buffer;
        ret = inflate(&stream, Z_NO_FLUSH);
        
        if (ret == Z_NEED_DICT || ret == Z_DATA_ERROR || ret == Z_MEM_ERROR) {
            inflateEnd(&stream);
            NSLog(@"[LC] Decompression error: %d", ret);
            return nil;
        }
        
        NSUInteger produced = sizeof(buffer) - stream.avail_out;
        [decompressed appendBytes:buffer length:produced];
    } while (ret != Z_STREAM_END);
    
    inflateEnd(&stream);
    return decompressed;
}

#pragma mark - Public API

@implementation LCDebExtractor

+ (BOOL)isValidDebFile:(NSString *)filePath {
    NSFileHandle *fh = [NSFileHandle fileForReadingAtPath:filePath];
    if (!fh) return NO;
    
    NSData *header = [fh readDataOfLength:AR_HEADER_SIZE];
    [fh closeFile];
    
    if (header.length != AR_HEADER_SIZE) return NO;
    
    return memcmp(header.bytes, AR_HEADER_MAGIC, AR_HEADER_SIZE) == 0;
}

+ (nullable NSData *)extractDataTarGzFromDeb:(NSString *)debPath error:(NSError **)error {
    NSFileHandle *fh = [NSFileHandle fileForReadingAtPath:debPath];
    if (!fh) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCDebExtractor" code:1 
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to open .deb file"}];
        }
        return nil;
    }
    
    // Read and verify ar header
    NSData *arHeader = [fh readDataOfLength:AR_HEADER_SIZE];
    if (arHeader.length != AR_HEADER_SIZE || memcmp(arHeader.bytes, AR_HEADER_MAGIC, AR_HEADER_SIZE) != 0) {
        [fh closeFile];
        if (error) {
            *error = [NSError errorWithDomain:@"LCDebExtractor" code:2 
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid .deb file format"}];
        }
        return nil;
    }
    
    // Iterate through ar entries
    NSData *dataTargzData = nil;
    while (YES) {
        NSData *entryHeader = [fh readDataOfLength:AR_ENTRY_SIZE];
        if (entryHeader.length != AR_ENTRY_SIZE) break;
        
        const uint8_t *entry = (const uint8_t *)entryHeader.bytes;
        
        // Parse entry header
        NSString *name = _trimArString((const char *)entry, 16);
        NSString *sizeStr = _trimArString((const char *)(entry + 48), 10);
        NSUInteger size = sizeStr.length > 0 ? strtol(sizeStr.UTF8String, NULL, 10) : 0;
        
        if (size == 0) break;
        
        NSLog(@"[LC] ar entry: %@, size: %lu", name, (unsigned long)size);
        
        if ([name hasPrefix:@"data.tar.gz"] || [name isEqualToString:@"data.tar.gz"]) {
            dataTargzData = [fh readDataOfLength:size];
            break;
        } else {
            // Skip this entry
            [fh seekToFileOffset:[fh offsetInFile] + size + (size % 2)];  // entries are aligned to 2-byte boundary
        }
    }
    
    [fh closeFile];
    
    if (!dataTargzData) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCDebExtractor" code:3 
                                    userInfo:@{NSLocalizedDescriptionKey: @"data.tar.gz not found in .deb"}];
        }
        return nil;
    }
    
    // Decompress gzip
    NSData *decompressed = _decompressGzip(dataTargzData);
    if (!decompressed) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCDebExtractor" code:4 
                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to decompress data.tar.gz"}];
        }
        return nil;
    }
    
    return decompressed;
}

+ (NSDictionary<NSString *, NSData *> *)parseTarForDylibs:(NSData *)tarData {
    NSMutableDictionary<NSString *, NSData *> *dylibs = [NSMutableDictionary dictionary];
    
    if (!tarData || tarData.length == 0) return dylibs;
    
    const uint8_t *data = (const uint8_t *)tarData.bytes;
    NSUInteger offset = 0;
    NSUInteger length = tarData.length;
    
    while (offset + TAR_HEADER_SIZE <= length) {
        const uint8_t *header = data + offset;
        
        // Check for end of archive (two consecutive 512-byte blocks of zeros)
        BOOL allZeros = YES;
        for (NSUInteger i = 0; i < TAR_HEADER_SIZE; i++) {
            if (header[i] != 0) {
                allZeros = NO;
                break;
            }
        }
        if (allZeros) break;
        
        // Get file info
        NSString *fileName = _getTarFileName(header);
        NSUInteger fileSize = _parseTarSize((const char *)(header + 124), 12);
        char typeFlag = *(header + TAR_TYPEFLAG_OFFSET);
        
        NSLog(@"[LC] tar entry: %@, size: %lu, type: %c", fileName, (unsigned long)fileSize, typeFlag);
        
        // Check if this is a dylib in the correct path
        if (fileName && [fileName hasPrefix:@"Library/MobileSubstrate/DynamicLibraries/"] && [fileName hasSuffix:@".dylib"]) {
            offset += TAR_HEADER_SIZE;
            
            if (offset + fileSize <= length) {
                NSData *fileData = [NSData dataWithBytes:(data + offset) length:fileSize];
                dylibs[fileName.lastPathComponent] = fileData;
                NSLog(@"[LC] Found dylib: %@", fileName.lastPathComponent);
            }
            
            // Move to next 512-byte aligned position
            offset += ((fileSize + 511) / 512) * 512;
        } else {
            offset += TAR_HEADER_SIZE;
            offset += ((fileSize + 511) / 512) * 512;
        }
    }
    
    return dylibs;
}

+ (NSDictionary<NSString *, NSDictionary *> *)parseTarForPlistFilters:(NSData *)tarData {
    NSMutableDictionary<NSString *, NSDictionary *> *filters = [NSMutableDictionary dictionary];
    
    if (!tarData || tarData.length == 0) return filters;
    
    const uint8_t *data = (const uint8_t *)tarData.bytes;
    NSUInteger offset = 0;
    NSUInteger length = tarData.length;
    
    while (offset + TAR_HEADER_SIZE <= length) {
        const uint8_t *header = data + offset;
        
        // Check for end of archive
        BOOL allZeros = YES;
        for (NSUInteger i = 0; i < TAR_HEADER_SIZE; i++) {
            if (header[i] != 0) {
                allZeros = NO;
                break;
            }
        }
        if (allZeros) break;
        
        NSString *fileName = _getTarFileName(header);
        NSUInteger fileSize = _parseTarSize((const char *)(header + 124), 12);
        
        // Check if this is a plist in the correct path
        if (fileName && [fileName hasPrefix:@"Library/MobileSubstrate/DynamicLibraries/"] && [fileName hasSuffix:@".plist"]) {
            offset += TAR_HEADER_SIZE;
            
            if (offset + fileSize <= length) {
                NSData *fileData = [NSData dataWithBytes:(data + offset) length:fileSize];
                
                // Parse plist
                NSError *plistError = nil;
                NSDictionary *plist = (NSDictionary *)[NSPropertyListSerialization propertyListWithData:fileData
                                                                                                 options:NSPropertyListImmutable
                                                                                                  format:NULL
                                                                                                   error:&plistError];
                if (plist && [plist isKindOfClass:[NSDictionary class]]) {
                    NSString *name = [[fileName.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@".dylib"];
                    filters[name] = plist;
                    NSLog(@"[LC] Found plist filter for: %@", name);
                }
            }
            
            offset += ((fileSize + 511) / 512) * 512;
        } else {
            offset += TAR_HEADER_SIZE;
            offset += ((fileSize + 511) / 512) * 512;
        }
    }
    
    return filters;
}

+ (nullable NSArray<LCExtractedDylib *> *)extractDylibsFromDeb:(NSString *)debPath
                                                         error:(NSError **)error {
    // Extract data.tar.gz
    NSData *tarData = [self extractDataTarGzFromDeb:debPath error:error];
    if (!tarData) return nil;
    
    // Parse tar for dylibs and plist filters
    NSDictionary<NSString *, NSData *> *dylibsDict = [self parseTarForDylibs:tarData];
    NSDictionary<NSString *, NSDictionary *> *filtersDict = [self parseTarForPlistFilters:tarData];
    
    if (dylibsDict.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"LCDebExtractor" code:5 
                                    userInfo:@{NSLocalizedDescriptionKey: @"No dylibs found in .deb package"}];
        }
        return nil;
    }
    
    // Combine dylibs with their filters
    NSMutableArray<LCExtractedDylib *> *result = [NSMutableArray array];
    for (NSString *dylibName in dylibsDict) {
        LCExtractedDylib *extracted = [LCExtractedDylib new];
        extracted.name = dylibName;
        extracted.data = dylibsDict[dylibName];
        extracted.filter = filtersDict[dylibName];
        [result addObject:extracted];
    }
    
    return result;
}

@end
