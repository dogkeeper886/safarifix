#include <syslog.h>

// The core's log goes to the phone's log, where tools/inspect.sh log reads it.
void sf_syslog(const char *line) { syslog(LOG_NOTICE, "%s", line); }
