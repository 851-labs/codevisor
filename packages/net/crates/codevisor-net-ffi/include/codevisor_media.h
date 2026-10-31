#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

int64_t codevisor_media_send_frame(
    uint64_t session, uint8_t stream, bool keyframe, bool has_ltr_token, uint64_t ltr_token, const void *meta,
    size_t meta_len, const void *data, size_t data_len);

const void *codevisor_media_bytes(uint64_t bytes, size_t *len);
