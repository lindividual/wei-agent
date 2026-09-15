// The C half of the host boundary: what Swift can see, and nothing else.
//
// Deliberately not `moonbit.h`. Swift has no business holding a MoonBit reference — the boundary
// is text in both directions, and every type here is a plain C one so that this header is the
// whole of what the Swift compiler has to understand about the runtime behind it.

#ifndef PI_SHELL_C_H
#define PI_SHELL_C_H

#include <stdint.h>

// ── the MoonBit side, implemented over there ───────────────────────────────
//
// Called by `pi_shell_start`, and again from wherever the host settles state. Both are in
// `macos/appffi/inbox.c`.

// Prepares the MoonBit runtime. Once, on the main thread, before anything else.
void pi_shell_boot(int32_t argc, const char **argv);
// Adds a line to the inbox. Thread-safe, and the caller keeps its buffer.
void pi_shell_post(const char *text, int32_t len);

// ── the host side ─────────────────────────────────────────────────────────
//
// `pi_shell_emit` is called by MoonBit for every line of output, on the thread that started it.
// It is defined in `PiShellC.c` rather than in `inbox.c` because the host — not the runtime — is
// what decides where a line goes.

// Starts the agent. Blocks until the app is asked to quit, so call it on a thread of your own.
void pi_shell_start(void);

// Where output goes. One sink per process, because there is one MoonBit runtime per process.
void pi_shell_set_emit(void (*emit)(const char *bytes, int32_t len));

// Sends one command: a prompt, or one of the words the MoonBit side recognises.
void pi_shell_send(const char *text);

#endif
