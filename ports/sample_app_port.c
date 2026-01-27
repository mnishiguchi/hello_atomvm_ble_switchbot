#include "sample_app_port.h"

#include <string.h>

#include <context.h>
#include <globalcontext.h>
#include <mailbox.h>
#include <port.h>
#include <portnifloader.h>
#include <term.h>

// #define ENABLE_TRACE
#include <trace.h>

enum
{
    OPCODE_PING = 0x01,
    OPCODE_ECHO = 0x02
};

static term make_error(Context *ctx, uint8_t code)
{
    // Reply: <<0x01, code>>
    uint8_t out[2] = { 0x01, code };
    return term_from_literal_binary(out, sizeof(out), &ctx->heap, ctx->global);
}

static term make_ok_with_payload(Context *ctx, const uint8_t *payload, size_t payload_len)
{
    // Reply: <<0x00, payload::binary>>
    size_t out_len = 1 + payload_len;

    term bin = term_create_uninitialized_binary(out_len, &ctx->heap, ctx->global);
    uint8_t *out = (uint8_t *) term_binary_data(bin);

    out[0] = 0x00;

    if (payload_len > 0) {
        memcpy(out + 1, payload, payload_len);
    }

    return bin;
}

static term handle_call(Context *ctx, term req)
{
    if (!term_is_binary(req)) {
        return make_error(ctx, 0x10); // not a binary
    }

    const uint8_t *data = (const uint8_t *) term_binary_data(req);
    size_t len = term_binary_size(req);

    if (len < 1) {
        return make_error(ctx, 0x11); // missing opcode
    }

    uint8_t opcode = data[0];

    switch (opcode) {
        case OPCODE_PING: {
            static const uint8_t pong[] = { 'P', 'O', 'N', 'G' };
            return make_ok_with_payload(ctx, pong, sizeof(pong));
        }

        case OPCODE_ECHO:
            // Echo everything after the opcode byte.
            return make_ok_with_payload(ctx, data + 1, len - 1);

        default:
            return make_error(ctx, 0x12); // unknown opcode
    }
}

/*
 * Native handler: runs inside the AtomVM scheduler.
 * Process at most one mailbox message per invocation.
 */
static NativeHandlerResult sample_app_port_native_handler(Context *ctx)
{
    term msg;

    // Copy the next mailbox message term into this context heap (does not remove it).
    if (!mailbox_peek(ctx, &msg)) {
        return NativeContinue;
    }

    // Remove the message now that we have a copy.
    mailbox_remove_message(&ctx->mailbox, &ctx->heap);

    // Parse the :port.call/2 gen-call message.
    GenMessage gen_message;
    enum GenMessageParseResult parse_result = port_parse_gen_message(msg, &gen_message);

    // Ignore anything that isn't a gen-call request.
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

    // AtomVM will schedule this context and call the native handler.
    ctx->native_handler = sample_app_port_native_handler;

    return ctx;
}

REGISTER_PORT_DRIVER(
    sample_app_port,
    sample_app_port_init,
    sample_app_port_destroy,
    sample_app_port_create_port);
