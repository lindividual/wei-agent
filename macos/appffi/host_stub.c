// The host callback, when there is no host.
//
// `wei_emit` belongs to whoever embeds this: the app defines it, the command-line client
// defines it, and `swift build` links that definition in. But `moon test` links nothing but
// MoonBit, and a missing symbol is a link error rather than a test result — so there is a weak
// default here, and a strong definition anywhere else wins.
//
// Weak rather than a plain function in the archive: the archive member is pulled in for
// `wei_post` regardless, so a strong definition here would collide with the host's.

#include <stdint.h>

__attribute__((weak)) void wei_emit(const char *bytes, int32_t len) {
  (void)bytes;
  (void)len;
}
