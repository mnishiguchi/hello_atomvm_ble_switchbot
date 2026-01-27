#ifndef __SAMPLE_APP_PORT_H__
#define __SAMPLE_APP_PORT_H__

#include <context.h>
#include <globalcontext.h>
#include <term.h>

#ifdef __cplusplus
extern "C" {
#endif

void sample_app_port_init(GlobalContext *global);
void sample_app_port_destroy(GlobalContext *global);
Context *sample_app_port_create_port(GlobalContext *global, term opts);

#ifdef __cplusplus
}
#endif

#endif
