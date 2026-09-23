#import "ROMArchive.h"
#include "../../ThirdParty/libarchive/libarchive/archive.h"
#include "../../ThirdParty/libarchive/libarchive/archive_entry.h"
#include <cstdio>

@implementation ROMArchive
+ (BOOL)extractURL:(NSURL *)source toDirectory:(NSURL *)destination error:(NSError **)error {
    auto reader = archive_read_new();
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    NSString *failure = nil;
    auto manager = NSFileManager.defaultManager;
    const uint64_t byteLimit = 8ULL * 1024 * 1024 * 1024;
    uint64_t total = 0;
    unsigned entries = 0;
    if (archive_read_open_filename(reader, source.fileSystemRepresentation, 65536) != ARCHIVE_OK) {
        failure = NSLocalizedString(@"无法打开压缩包，文件可能损坏或需要密码", nil);
    } else {
        struct archive_entry *entry;
        int status;
        while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
            if (++entries > 10000) { failure = NSLocalizedString(@"压缩包文件数量超过 10000 个", nil); break; }
            const char *raw = archive_entry_pathname_utf8(entry);
            if (!raw) raw = archive_entry_pathname(entry);
            NSString *path = raw ? [NSString stringWithUTF8String:raw] : nil;
            path = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if (!path || [path hasPrefix:@"/"] || [path containsString:@":"] ||
                [[path componentsSeparatedByString:@"/"] containsObject:@".."] ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
                failure = NSLocalizedString(@"压缩包含有不安全的路径或链接", nil); break;
            }
            if (archive_entry_is_encrypted(entry) > 0) { failure = NSLocalizedString(@"请先解锁带密码的压缩包，再导入解压后的文件", nil); break; }
            if (archive_entry_size(entry) < 0 || (uint64_t)archive_entry_size(entry) > byteLimit - total) {
                failure = NSLocalizedString(@"压缩包展开后超过 8 GB，请分批导入", nil); break;
            }
            NSURL *target = [destination URLByAppendingPathComponent:path];
            auto type = archive_entry_filetype(entry);
            if (type != AE_IFDIR && type != AE_IFREG) { failure = NSLocalizedString(@"压缩包含有不支持的特殊文件", nil); break; }
            NSError *ioError;
            NSURL *directory = type == AE_IFDIR ? target : target.URLByDeletingLastPathComponent;
            if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&ioError]) {
                failure = ioError.localizedDescription; break;
            }
            if (type == AE_IFDIR) continue;
            // Exclusive creation also rejects duplicate names and file/directory collisions.
            FILE *output = fopen(target.fileSystemRepresentation, "wbx");
            if (!output) { failure = NSLocalizedString(@"无法写入解压文件，或包内存在重复文件名", nil); break; }
            char buffer[65536];
            la_ssize_t count;
            while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                if ((uint64_t)count > byteLimit - total) { failure = NSLocalizedString(@"解压大小超过 8 GB", nil); break; }
                total += count;
                if (fwrite(buffer, 1, count, output) != (size_t)count) { failure = NSLocalizedString(@"存储空间不足或写入失败", nil); break; }
            }
            if (count < 0) failure = NSLocalizedString(@"压缩数据损坏、密码错误或压缩方式不受支持", nil);
            if (fclose(output) != 0) failure = NSLocalizedString(@"解压文件写入失败", nil);
            if (failure) break;
        }
        if (!failure && status != ARCHIVE_EOF) failure = NSLocalizedString(@"压缩包不完整、损坏或缺少分卷", nil);
    }
    archive_read_free(reader);
    if (failure && error) *error = [NSError errorWithDomain:@"com.duods.import" code:1
                                                  userInfo:@{NSLocalizedDescriptionKey:failure}];
    return failure == nil;
}
@end
