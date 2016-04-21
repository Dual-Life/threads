#ifndef _THREADS_H_
#define _THREADS_H_

/* Needed for 5.8.0 */
#ifndef CLONEf_JOIN_IN
#  define CLONEf_JOIN_IN        8
#endif
#ifndef SAVEBOOL
#  define SAVEBOOL(a)
#endif

/* Supposed to be in Winbase.h */
#ifdef WIN32
#  ifndef STACK_SIZE_PARAM_IS_A_RESERVATION
#    define STACK_SIZE_PARAM_IS_A_RESERVATION 0x00010000
#  endif
#endif

#endif
