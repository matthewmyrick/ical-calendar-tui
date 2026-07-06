/*
 * eventkit_shim.h — the ONLY interop surface between Zig and EventKit
 * (CODING_STANDARDS §7). The ABI carries only int error codes, double unix
 * timestamps, and char*+len UTF-8 buffers. No ObjC types cross this line.
 *
 * Threading: every function here BLOCKS and is called from the poller
 * thread (never the UI thread). ek_request_access triggers the macOS TCC
 * prompt on first call and blocks until the user answers.
 *
 * Memory: buffers returned through out-parameters are malloc'd copies owned
 * by the caller; free them with ek_free (and nothing else). The shim keeps
 * one process-lifetime EKEventStore internally (creating one per fetch is
 * slow and re-prompts on some macOS versions — SPEC §5b).
 */

#ifndef ICAL_CALENDAR_TUI_EVENTKIT_SHIM_H
#define ICAL_CALENDAR_TUI_EVENTKIT_SHIM_H

#include <stddef.h>

/* Error codes: 0 success, negative failure. */
enum {
    EK_OK = 0,
    EK_ERR_ACCESS_DENIED = -1, /* user denied or restricted by policy   */
    EK_ERR_INTERNAL = -2,      /* EventKit/serialization failure        */
    EK_ERR_OOM = -3,           /* allocation failure                    */
};

/*
 * Request full calendar access (macOS 14+ API). Blocks until the system
 * prompt (first run) is answered or the existing grant is read. Safe to
 * call repeatedly; only the first call can prompt.
 */
int ek_request_access(void);

/*
 * Fetch all events in [from_unix, to_unix] as a UTF-8 JSON array using the
 * same field names as `ical -o json` (one parser on the Zig side, two
 * sources — SPEC §5b), plus "calendar_color": "#RRGGBB" per event.
 *
 * On EK_OK, "json_utf8" and "len" hold a malloc'd buffer (not
 * NUL-terminated) that the caller must release with ek_free. On error they
 * are untouched.
 */
int ek_fetch_events(double from_unix, double to_unix,
                    char **json_utf8, size_t *len);

/* Free any buffer returned by this shim. NULL is a no-op. */
void ek_free(char *ptr);

#endif /* ICAL_CALENDAR_TUI_EVENTKIT_SHIM_H */
