#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Represents a dylib extracted from a .deb package
 */
@interface LCExtractedDylib : NSObject
@property (nonatomic, copy) NSString *name;           // e.g., "TweakName.dylib"
@property (nonatomic, strong) NSData *data;           // The dylib binary data
@property (nonatomic, copy, nullable) NSDictionary *filter;  // Parsed .plist filter (Bundles array, etc)
@end

/**
 * Extracts and parses Debian (.deb) package files
 */
@interface LCDebExtractor : NSObject

/**
 * Checks if a file is a valid .deb archive
 * 
 * @param filePath Path to the file
 * @return YES if valid .deb format, NO otherwise
 */
+ (BOOL)isValidDebFile:(NSString *)filePath;

/**
 * Extracts all dylib files from a .deb package
 *
 * @param debPath Path to the .deb file
 * @param error Output parameter for error information
 * @return Array of LCExtractedDylib objects, or nil if extraction failed
 */
+ (nullable NSArray<LCExtractedDylib *> *)extractDylibsFromDeb:(NSString *)debPath
                                                         error:(NSError **)error;

/**
 * Extracts data.tar.gz from a .deb file and decompresses it
 *
 * @param debPath Path to the .deb file
 * @param error Output parameter for error information
 * @return Decompressed tar data, or nil if extraction failed
 */
+ (nullable NSData *)extractDataTarGzFromDeb:(NSString *)debPath
                                      error:(NSError **)error;

/**
 * Parses a decompressed tar file looking for dylibs
 *
 * @param tarData The decompressed tar data
 * @return Dictionary mapping dylib names to their binary data
 */
+ (NSDictionary<NSString *, NSData *> *)parseTarForDylibs:(NSData *)tarData;

/**
 * Parses a decompressed tar file looking for .plist filter files
 *
 * @param tarData The decompressed tar data
 * @return Dictionary mapping dylib names (without extension) to their filter plist dictionaries
 */
+ (NSDictionary<NSString *, NSDictionary *> *)parseTarForPlistFilters:(NSData *)tarData;

NS_ASSUME_NONNULL_END
