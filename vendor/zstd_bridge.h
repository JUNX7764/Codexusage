#ifndef CU_ZSTD_BRIDGE_H
#define CU_ZSTD_BRIDGE_H
#include <stddef.h>

/* Swift 侧可见的最小桥接；实现见 zstd_bridge.c（内含上游 zstddeclib.c v1.5.7） */
unsigned long long cu_zstd_content_size(const unsigned char *src, size_t srcLen);
size_t cu_zstd_decompress(const unsigned char *src, size_t srcLen,
                          unsigned char *dst, size_t dstCap);

#endif
