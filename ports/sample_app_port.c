#include "sample_app_port.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <context.h>
#include <globalcontext.h>
#include <mailbox.h>
#include <port.h>
#include <portnifloader.h>
#include <term.h>

// #define ENABLE_TRACE
#include <trace.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "nvs_flash.h"

#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

#define TAG "sample_app_port"

// SwitchBot constants:
// - Company ID in Manufacturer Data = 0x0969
// - Service Data UUID (16-bit) = 0xFD3D
// SwitchBot often splits Manufacturer Data (ADV_IND) and Service Data (SCAN_RSP).
#define SWITCHBOT_COMPANY_ID_LE0 0x69
#define SWITCHBOT_COMPANY_ID_LE1 0x09
#define SWITCHBOT_SVC_UUID16_LE0 0x3d
#define SWITCHBOT_SVC_UUID16_LE1 0xfd

enum
{
    OPCODE_PING = 0x01,
    OPCODE_ECHO = 0x02,

    OPCODE_BLE_START = 0x10,
    OPCODE_BLE_STOP = 0x11,

    OPCODE_LATEST = 0x12,
    OPCODE_LATEST_FOR = 0x13
};

static term make_error(Context *ctx, uint8_t code)
{
    uint8_t out[2] = { 0x01, code };
    return term_from_literal_binary(out, sizeof(out), &ctx->heap, ctx->global);
}

static term make_ok_with_payload(Context *ctx, const uint8_t *payload, size_t payload_len)
{
    size_t out_len = 1 + payload_len;

    term bin = term_create_uninitialized_binary(out_len, &ctx->heap, ctx->global);
    uint8_t *out = (uint8_t *) term_binary_data(bin);

    out[0] = 0x00;
    if (payload_len > 0) {
        memcpy(out + 1, payload, payload_len);
    }
    return bin;
}

// ----- Minimal ADV parser (no ble_hs_adv_parse_fields dependency) -----

typedef struct
{
    const uint8_t *mfg;
    uint8_t mfg_len;

    const uint8_t *svc; // service data payload after UUID16
    uint8_t svc_len;

    bool has_mfg;
    bool has_svc;
} adv_extract_t;

static void adv_extract_init(adv_extract_t *e)
{
    memset(e, 0, sizeof(*e));
}

// Parses AD structures: [len][type][value...]
static void adv_extract(const uint8_t *data, uint8_t data_len, adv_extract_t *out)
{
    adv_extract_init(out);

    uint8_t i = 0;
    while (i < data_len) {
        uint8_t len = data[i];
        if (len == 0) {
            break;
        }

        // Need i + 1 + len <= data_len; otherwise malformed.
        if ((uint16_t) i + (uint16_t) len >= (uint16_t) data_len) {
            break;
        }

        uint8_t type = data[i + 1];
        const uint8_t *val = &data[i + 2];
        uint8_t val_len = (uint8_t) (len - 1);

        // Manufacturer Specific Data
        if (type == 0xFF && val_len >= 2) {
            out->mfg = val;
            out->mfg_len = val_len;
            out->has_mfg = true;
        }

        // Service Data - 16-bit UUID
        if (type == 0x16 && val_len >= 2) {
            // UUID is little-endian in the payload
            if (val[0] == SWITCHBOT_SVC_UUID16_LE0 && val[1] == SWITCHBOT_SVC_UUID16_LE1) {
                out->svc = val + 2;
                out->svc_len = (uint8_t) (val_len - 2);
                out->has_svc = true;
            }
        }

        i = (uint8_t) (i + 1 + len);
    }
}

// ----- Cache (merge ADV_IND + SCAN_RSP) -----

#define MAX_DEVICES 12
#define MAX_BLE_DATA 31

typedef struct
{
    uint8_t addr[6];
    bool in_use;

    int8_t rssi;

    bool have_mfg;
    uint8_t mfg_len;
    uint8_t mfg[MAX_BLE_DATA];

    bool have_svc;
    uint8_t svc_len;
    uint8_t svc[MAX_BLE_DATA];

    uint16_t device_id; // derived from mfg[6..7] if available
    bool have_device_id;
} device_cache_t;

static device_cache_t g_devices[MAX_DEVICES];
static int g_latest_index = -1; // index into g_devices
static SemaphoreHandle_t g_lock;

// NimBLE state
static bool g_ble_started = false;
static uint8_t g_own_addr_type;

// Find existing entry by address or allocate a new one
static int cache_find_or_alloc(const uint8_t addr[6])
{
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (g_devices[i].in_use && memcmp(g_devices[i].addr, addr, 6) == 0) {
            return i;
        }
    }
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (!g_devices[i].in_use) {
            memset(&g_devices[i], 0, sizeof(g_devices[i]));
            g_devices[i].in_use = true;
            memcpy(g_devices[i].addr, addr, 6);
            return i;
        }
    }
    return -1;
}

// SwitchBot sanity checks (company ID in mfg data, etc.)
static bool is_switchbot_mfg(const uint8_t *mfg, uint8_t mfg_len)
{
    if (mfg_len < 2) {
        return false;
    }
    return (mfg[0] == SWITCHBOT_COMPANY_ID_LE0 && mfg[1] == SWITCHBOT_COMPANY_ID_LE1);
}

static void update_device_id(device_cache_t *d)
{
    // Your reference code uses manufacturerData[6]*256 + manufacturerData[7]
    // (big-endian). Only set if we have enough bytes.
    if (d->have_mfg && d->mfg_len >= 8) {
        d->device_id = (uint16_t) ((uint16_t) d->mfg[6] << 8) | (uint16_t) d->mfg[7];
        d->have_device_id = true;
    }
}

static bool maybe_mark_latest(int idx)
{
    // Consider a frame "merged" when we have both pieces and it looks like SwitchBot.
    device_cache_t *d = &g_devices[idx];
    if (d->have_mfg && d->have_svc && is_switchbot_mfg(d->mfg, d->mfg_len)) {
        update_device_id(d);
        g_latest_index = idx;
        return true;
    }
    return false;
}

// ----- NimBLE gap callback -----

static int gap_event_cb(struct ble_gap_event *event, void *arg);

static void start_scan(void)
{
    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));

    params.passive = 0; // active scan
    params.itvl = 0x0010;
    params.window = 0x0010;
    params.filter_duplicates = 0;

    ESP_LOGI(TAG,
        "scan params passive=%u itvl=%u window=%u filter_duplicates=%u",
        (unsigned) params.passive,
        (unsigned) params.itvl,
        (unsigned) params.window,
        (unsigned) params.filter_duplicates);

    int rc = ble_gap_disc(g_own_addr_type, BLE_HS_FOREVER, &params, gap_event_cb, NULL);
    ESP_LOGI(TAG, "ble_gap_disc rc=%d", rc);
}

static void stop_scan(void)
{
    int rc = ble_gap_disc_cancel();
    ESP_LOGI(TAG, "ble_gap_disc_cancel rc=%d", rc);
}

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &g_own_addr_type);
    ESP_LOGI(TAG, "ble_hs_id_infer_auto rc=%d, addr_type=%u", rc, g_own_addr_type);
    start_scan();
}

static void host_task(void *param)
{
    (void) param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void) arg;

    switch (event->type) {
        case BLE_GAP_EVENT_DISC: {
            const struct ble_gap_disc_desc *desc = &event->disc;

            adv_extract_t ex;
            adv_extract(desc->data, desc->length_data, &ex);

            // Debug: confirm we are actually seeing adv/scan-rsp data
            ESP_LOGD(
                TAG,
                "DISC evtype=%u rssi=%d len=%u has_mfg=%d(mfg_len=%u) has_svc=%d(svc_len=%u)",
                (unsigned) desc->event_type,
                (int) desc->rssi,
                (unsigned) desc->length_data,
                (int) ex.has_mfg,
                (unsigned) ex.mfg_len,
                (int) ex.has_svc,
                (unsigned) ex.svc_len);

            if (!ex.has_mfg && !ex.has_svc) {
                return 0;
            }

            uint8_t addr[6];
            memcpy(addr, desc->addr.val, 6);

            if (g_lock) {
                xSemaphoreTake(g_lock, portMAX_DELAY);
            }

            int idx = cache_find_or_alloc(addr);
            if (idx >= 0) {
                device_cache_t *d = &g_devices[idx];

                bool was_merged = d->have_mfg && d->have_svc && is_switchbot_mfg(d->mfg, d->mfg_len);

                d->rssi = desc->rssi;

                if (ex.has_mfg && ex.mfg_len <= MAX_BLE_DATA) {
                    d->have_mfg = true;
                    d->mfg_len = ex.mfg_len;
                    memcpy(d->mfg, ex.mfg, ex.mfg_len);
                }
                if (ex.has_svc && ex.svc_len <= MAX_BLE_DATA) {
                    d->have_svc = true;
                    d->svc_len = ex.svc_len;
                    memcpy(d->svc, ex.svc, ex.svc_len);
                }

                bool merged_now = maybe_mark_latest(idx);

                // Log only when we transition into a valid merged SwitchBot frame.
                if (!was_merged && merged_now) {
                    ESP_LOGI(
                        TAG,
                        "MERGED addr=%02x:%02x:%02x:%02x:%02x:%02x rssi=%d mfg_len=%u svc_len=%u",
                        d->addr[5], d->addr[4], d->addr[3], d->addr[2], d->addr[1], d->addr[0],
                        (int) d->rssi,
                        (unsigned) d->mfg_len,
                        (unsigned) d->svc_len);
                }
            }

            if (g_lock) {
                xSemaphoreGive(g_lock);
            }

            return 0;
        }

        case BLE_GAP_EVENT_DISC_COMPLETE:
            // Restart scan automatically
            start_scan();
            return 0;

        default:
            return 0;
    }
}

// ----- Port call handling -----

static term reply_latest(Context *ctx, const device_cache_t *d)
{
    // payload:
    // <<addr:6, rssi:s8, svc_len:u8, svc:svc_len, mfg_len:u8, mfg:mfg_len>>
    size_t payload_len = 6 + 1 + 1 + d->svc_len + 1 + d->mfg_len;

    term bin = term_create_uninitialized_binary(1 + payload_len, &ctx->heap, ctx->global);
    uint8_t *out = (uint8_t *) term_binary_data(bin);

    out[0] = 0x00;

    uint8_t *p = out + 1;
    memcpy(p, d->addr, 6);
    p += 6;
    *p++ = (uint8_t) d->rssi;

    *p++ = d->svc_len;
    memcpy(p, d->svc, d->svc_len);
    p += d->svc_len;

    *p++ = d->mfg_len;
    memcpy(p, d->mfg, d->mfg_len);
    p += d->mfg_len;

    return bin;
}

static term handle_call(Context *ctx, term req)
{
    if (!term_is_binary(req)) {
        return make_error(ctx, 0x10);
    }

    const uint8_t *data = (const uint8_t *) term_binary_data(req);
    size_t len = term_binary_size(req);

    if (len < 1) {
        return make_error(ctx, 0x11);
    }

    uint8_t opcode = data[0];

    switch (opcode) {
        case OPCODE_PING: {
            static const uint8_t pong[] = { 'P', 'O', 'N', 'G' };
            return make_ok_with_payload(ctx, pong, sizeof(pong));
        }

        case OPCODE_ECHO:
            return make_ok_with_payload(ctx, data + 1, len - 1);

        case OPCODE_BLE_START: {
            if (!g_ble_started) {
                // lazy init
                esp_err_t err;

                err = nvs_flash_init();
                if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
                    nvs_flash_erase();
                    err = nvs_flash_init();
                }
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "nvs_flash_init failed: %d", (int) err);
                    return make_error(ctx, 0x30);
                }

                nimble_port_init();
                ble_hs_cfg.sync_cb = on_sync;

                g_lock = xSemaphoreCreateMutex();
                g_ble_started = true;

                nimble_port_freertos_init(host_task);
            } else {
                start_scan();
            }

            uint8_t ok = 0x01;
            return make_ok_with_payload(ctx, &ok, 1);
        }

        case OPCODE_BLE_STOP: {
            if (!g_ble_started) {
                return make_error(ctx, 0x32);
            }
            stop_scan();
            uint8_t ok = 0x01;
            return make_ok_with_payload(ctx, &ok, 1);
        }

        case OPCODE_LATEST: {
            if (!g_ble_started) {
                return make_error(ctx, 0x40);
            }

            if (g_lock) {
                xSemaphoreTake(g_lock, portMAX_DELAY);
            }
            int idx = g_latest_index;
            if (idx < 0) {
                if (g_lock) {
                    xSemaphoreGive(g_lock);
                }
                return make_error(ctx, 0x41); // no data yet
            }
            device_cache_t snap = g_devices[idx];
            if (g_lock) {
                xSemaphoreGive(g_lock);
            }

            return reply_latest(ctx, &snap);
        }

        case OPCODE_LATEST_FOR: {
            if (!g_ble_started) {
                return make_error(ctx, 0x40);
            }
            if (len < 1 + 2) {
                return make_error(ctx, 0x42);
            }

            uint16_t wanted = (uint16_t) ((uint16_t) data[1] << 8) | (uint16_t) data[2];

            if (g_lock) {
                xSemaphoreTake(g_lock, portMAX_DELAY);
            }

            int found = -1;
            for (int i = 0; i < MAX_DEVICES; i++) {
                if (!g_devices[i].in_use) {
                    continue;
                }
                if (!g_devices[i].have_mfg || !g_devices[i].have_svc) {
                    continue;
                }
                if (!is_switchbot_mfg(g_devices[i].mfg, g_devices[i].mfg_len)) {
                    continue;
                }
                update_device_id(&g_devices[i]);
                if (g_devices[i].have_device_id && g_devices[i].device_id == wanted) {
                    found = i;
                    break;
                }
            }

            if (found < 0) {
                if (g_lock) {
                    xSemaphoreGive(g_lock);
                }
                return make_error(ctx, 0x43);
            }

            device_cache_t snap = g_devices[found];
            if (g_lock) {
                xSemaphoreGive(g_lock);
            }

            return reply_latest(ctx, &snap);
        }

        default:
            return make_error(ctx, 0x12);
    }
}

/*
 * Native handler: runs inside the AtomVM scheduler.
 * Process at most one mailbox message per invocation.
 */
static NativeHandlerResult sample_app_port_native_handler(Context *ctx)
{
    term msg;

    if (!mailbox_peek(ctx, &msg)) {
        return NativeContinue;
    }

    mailbox_remove_message(&ctx->mailbox, &ctx->heap);

    GenMessage gen_message;
    enum GenMessageParseResult parse_result = port_parse_gen_message(msg, &gen_message);

    if (parse_result != GenCallMessage) {
        return NativeContinue;
    }

    term reply = handle_call(ctx, gen_message.req);
    port_send_reply(ctx, gen_message.pid, gen_message.ref, reply);

    return NativeContinue;
}

void sample_app_port_init(GlobalContext *global)
{
    (void) global;
    TRACE("sample_app_port_init\n");
}

void sample_app_port_destroy(GlobalContext *global)
{
    (void) global;
    TRACE("sample_app_port_destroy\n");
}

Context *sample_app_port_create_port(GlobalContext *global, term opts)
{
    (void) opts;

    Context *ctx = context_new(global);
    if (!ctx) {
        return NULL;
    }

    ctx->native_handler = sample_app_port_native_handler;
    return ctx;
}

REGISTER_PORT_DRIVER(
    sample_app_port,
    sample_app_port_init,
    sample_app_port_destroy,
    sample_app_port_create_port);
