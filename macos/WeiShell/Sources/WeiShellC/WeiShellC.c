// The two functions Swift calls, and the one the runtime calls back.

#include "WeiShellC.h"

#include <string.h>

// Implemented in MoonBit (`macos/appffi/app.mbt`).
extern void wei_run(void);

static void (*emit_sink)(const char *bytes, int32_t len);

// Called by MoonBit, from the thread running the agent.
void wei_emit(const char *bytes, int32_t len) {
  if (emit_sink != NULL) {
    emit_sink(bytes, len);
  }
}

void wei_start(void) { wei_run(); }

void wei_set_emit(void (*emit)(const char *bytes, int32_t len)) {
  emit_sink = emit;
}

void wei_send(const char *text) {
  wei_post(text, (int32_t)strlen(text));
}
