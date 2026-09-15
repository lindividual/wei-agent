// The two functions Swift calls, and the one the runtime calls back.

#include "PiShellC.h"

#include <string.h>

// Implemented in MoonBit (`macos/appffi/app.mbt`).
extern void pi_run(void);

static void (*emit_sink)(const char *bytes, int32_t len);

// Called by MoonBit, from the thread running the agent.
void pi_shell_emit(const char *bytes, int32_t len) {
  if (emit_sink != NULL) {
    emit_sink(bytes, len);
  }
}

void pi_shell_start(void) { pi_run(); }

void pi_shell_set_emit(void (*emit)(const char *bytes, int32_t len)) {
  emit_sink = emit;
}

void pi_shell_send(const char *text) {
  pi_shell_post(text, (int32_t)strlen(text));
}
