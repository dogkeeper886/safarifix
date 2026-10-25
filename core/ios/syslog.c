#include <syslog.h>

// The core's log goes to the phone's log, where tools/phone/log.sh reads it.
void sf_syslog(const char *line) { syslog(LOG_NOTICE, "%s", line); }
