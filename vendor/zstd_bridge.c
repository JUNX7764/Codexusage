// CodexUsage 桥接：vendor 的 zstddeclib.c（上游 zstd v1.5.7 单文件解码源，
// BSD-3-Clause，许可全文见 zstd-LICENSE）提供 zstandard 帧解码。
#include "zstddeclib.c"
#include "zstd_bridge.h"

unsigned long long cu_zstd_content_size(const unsigned char *src, size_t srcLen) {
    unsigned long long size = ZSTD_getFrameContentSize(src, srcLen);
    if (size == ZSTD_CONTENTSIZE_UNKNOWN || size == ZSTD_CONTENTSIZE_ERROR) return 0;
    return size;
}

size_t cu_zstd_decompress(const unsigned char *src, size_t srcLen,
                          unsigned char *dst, size_t dstCap) {
    size_t rc = ZSTD_decompress(dst, dstCap, src, srcLen);
    return ZSTD_isError(rc) ? 0 : rc;
}
