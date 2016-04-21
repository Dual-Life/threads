#ifndef _THREADS_H_
#define _THREADS_H_

/* Needed for 5.8.0 */
#ifndef CLONEf_JOIN_IN
#  define CLONEf_JOIN_IN        8
#endif
#ifndef SAVEBOOL
#  define SAVEBOOL(a)
#endif
/* Devel::PPPort bug workaround - Signals are safe under 5.8.0 */
#if ((PERL_REVISION == 5) && (PERL_VERSION == 8) && (PERL_SUBVERSION == 0))
#  define PERL_SIGNALS_UNSAFE_FLAG 0
#endif

#endif
