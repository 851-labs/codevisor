// The frame path of codevisor-media, beside uniffi's bindings (see codevisor_media_send_frame in src/lib.rs).
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

int64_t codevisor_media_send_frame(
    uint64_t session, uint8_t stream, bool keyframe, bool has_ltr_token, uint64_t ltr_token, const uint8_t *meta,
    size_t meta_len, const uint8_t *data, size_t data_len);

const uint8_t *codevisor_media_bytes(uint64_t bytes, size_t *len);
