#include <sqlite3.h>
#include <libproc.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
enum { LEAN_PROC_PIDPATH_MAX = PROC_PIDPATHINFO_MAXSIZE };
