// The one thing in this directory that C owns: the command inbox.
//
// Commands arrive from the host on the main thread and are read by MoonBit on the thread
// that runs the agent, so the queue needs a real lock — and the payload has to be copied
// out of the host's buffer before it returns. Both are reasons this is not a MoonBit
// global: the host's bytes are not MoonBit references and must never be treated as any.
//
// Text only, for now. Every font in the app can be reached from plain text, so the MVP
// does not need the attributed payload and the copying that would imply.

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Boots the MoonBit runtime. Called once, from the main thread, before anything else —
// `moonbit_runtime_init` captures the arguments the runtime reports to MoonBit code.
extern void moonbit_runtime_init(int argc, char **argv);
extern void moonbit_init(void);
// The entry point, defined in `app.mbt`. Runs on the host's worker thread and does not
// return until the app is asked to quit.
extern void wei_run(void);

typedef struct Message {
  char *text;
  int32_t len;
  struct Message *next;
} Message;

static Message *head;
static Message *tail;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

// ── called from the host ───────────────────────────────────────────────────

void wei_boot(int32_t argc, const char **argv) {
  // A host that has no arguments — a GUI app, say — should not have to invent an argv just to
  // satisfy the runtime, which reads the program name out of it.
  static const char *fallback[] = { "wei", NULL };
  if (argv == NULL) {
    argc = 1;
    argv = fallback;
  }
  moonbit_runtime_init(argc, (char **)argv);
  moonbit_init();
}

void wei_post(const char *text, int32_t len) {
  if (text == NULL || len <= 0) {
    return;
  }
  Message *message = (Message *)malloc(sizeof(Message));
  if (message == NULL) {
    return;
  }
  message->text = (char *)malloc((size_t)len + 1);
  if (message->text == NULL) {
    free(message);
    return;
  }
  memcpy(message->text, text, (size_t)len);
  message->text[len] = '\0';
  message->len = len;
  message->next = NULL;
  pthread_mutex_lock(&lock);
  if (tail == NULL) {
    head = message;
  } else {
    tail->next = message;
  }
  tail = message;
  pthread_mutex_unlock(&lock);
}

// ── called from MoonBit ────────────────────────────────────────────────────

// Copies the oldest message into `buffer`, or returns 0 when there is none. The queue
// hands over its own copy, so the caller never sees a buffer it does not own.
int32_t wei_recv(uint8_t *buffer, int32_t capacity) {
  if (buffer == NULL || capacity <= 0) {
    return 0;
  }
  pthread_mutex_lock(&lock);
  Message *message = head;
  if (message != NULL) {
    head = message->next;
    if (head == NULL) {
      tail = NULL;
    }
  }
  pthread_mutex_unlock(&lock);
  if (message == NULL) {
    return 0;
  }
  int32_t len = message->len < capacity ? message->len : capacity;
  memcpy(buffer, message->text, (size_t)len);
  free(message->text);
  free(message);
  return len;
}
