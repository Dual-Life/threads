#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef HAS_PPPORT_H
#  define NEED_newRV_noinc
#  define NEED_sv_2pv_nolen
#  include "ppport.h"
#  include "threads.h"
#endif

#ifdef USE_ITHREADS

#ifdef WIN32
#  include <windows.h>
   /* Supposed to be in Winbase.h */
#  ifndef STACK_SIZE_PARAM_IS_A_RESERVATION
#    define STACK_SIZE_PARAM_IS_A_RESERVATION 0x00010000
#  endif
#  include <win32thread.h>
#else
#  ifdef OS2
typedef perl_os_thread pthread_t;
#  else
#    include <pthread.h>
#  endif
#  include <thread.h>
#  define PERL_THREAD_SETSPECIFIC(k,v) pthread_setspecific(k,v)
#  ifdef OLD_PTHREADS_API
#    define PERL_THREAD_DETACH(t) pthread_detach(&(t))
#  else
#    define PERL_THREAD_DETACH(t) pthread_detach((t))
#  endif
#endif

/* Values for 'state' member */
#define PERL_ITHR_JOINABLE      0
#define PERL_ITHR_DETACHED      1
#define PERL_ITHR_JOINED        2
#define PERL_ITHR_FINISHED      4

typedef struct ithread_s {
    struct ithread_s *next;     /* Next thread in the list */
    struct ithread_s *prev;     /* Prev thread in the list */
    PerlInterpreter *interp;    /* The threads interpreter */
    /* Under PERL_IMPLICIT_SYS even the call to PerlMemShared_free() uses
     * aTHX, so the perl interpreter should not be freed before the threads
     * structure is deallocated.  Thus, we need two copies of the interpreter
     * pointer - one for destruction in the thread's context; the other for
     * freeing after the thread structure is deallocated.
     */
    PerlInterpreter *free_interp;
    UV tid;                     /* Threads module's thread id */
    perl_mutex mutex;           /* Mutex for updating things in this struct */
    UV count;                   /* How many SVs have a reference to us */
    int state;                  /* Detached, joined, finished, etc. */
    int gimme;                  /* Context of create */
    SV *init_function;          /* Code to run */
    SV *params;                 /* Args to pass function */
#ifdef WIN32
    DWORD  thr;                 /* OS's idea if thread id */
    HANDLE handle;              /* OS's waitable handle */
#else
    pthread_t thr;              /* OS's handle for the thread */
#endif
    UV stack_size;
} ithread;

/* Linked list of all threads */
static ithread *threads;

/* Protects the creation and destruction of threads*/
static perl_mutex create_destruct_mutex;

static UV tid_counter = 0;
static UV active_threads = 0;
#ifdef THREAD_CREATE_NEEDS_STACK
static UV default_stack_size = THREAD_CREATE_NEEDS_STACK;
#else
static UV default_stack_size = 0;
#endif
static IV page_size = 0;


#define MY_CXT_KEY "threads::_guts" XS_VERSION

typedef struct {
    ithread *thread;
} my_cxt_t;

START_MY_CXT


/* Used by Perl interpreter for thread context switching */
static void
Perl_ithread_set(pTHX_ ithread *thread)
{
    dMY_CXT;
    MY_CXT.thread = thread;
}

static ithread *
Perl_ithread_get(pTHX)
{
    dMY_CXT;
    return (MY_CXT.thread);
}


/* Free any data (such as the Perl interpreter) attached to an ithread
 * structure.  This is a bit like undef on SVs, where the SV isn't freed,
 * but the PVX is.  Must be called with thread->mutex already held.
 */
static void
S_ithread_clear(pTHX_ ithread *thread)
{
    PerlInterpreter *interp = thread->interp;
    if (interp) {
        dTHXa(interp);
        ithread *current_thread;

        PERL_SET_CONTEXT(interp);
        current_thread = Perl_ithread_get(aTHX);
        Perl_ithread_set(aTHX_ thread);

        SvREFCNT_dec(thread->init_function);

        SvREFCNT_dec(thread->params);
        thread->params = Nullsv;

        perl_destruct(interp);
        thread->interp = NULL;
    }
    PERL_SET_CONTEXT(aTHX);
}


/* Free an ithread structure and any attached data if its count == 0 */
static void
Perl_ithread_destruct(pTHX_ ithread *thread)
{
    PerlInterpreter *interp;
#ifdef WIN32
    HANDLE handle;
#endif

    MUTEX_LOCK(&thread->mutex);

    /* Thread is still in use */
    if (thread->count != 0) {
        MUTEX_UNLOCK(&thread->mutex);
        return;
    }

    /* Remove from circular list of threads */
    MUTEX_LOCK(&create_destruct_mutex);
    thread->next->prev = thread->prev;
    thread->prev->next = thread->next;
    thread->next = NULL;
    thread->prev = NULL;
    MUTEX_UNLOCK(&create_destruct_mutex);

    /* Thread is now disowned */
    S_ithread_clear(aTHX_ thread);
    interp = thread->free_interp;
    thread->free_interp = NULL;
#ifdef WIN32
    handle = thread->handle;
    thread->handle = 0;
#endif
    MUTEX_UNLOCK(&thread->mutex);
    MUTEX_DESTROY(&thread->mutex);
    PerlMemShared_free(thread);
    if (interp)
        perl_free(interp);
#ifdef WIN32
    if (handle)
        CloseHandle(handle);
#endif
}


/* Detach a thread */
static void
Perl_ithread_detach(pTHX_ ithread *thread)
{
    int cleanup;

    MUTEX_LOCK(&thread->mutex);
    if (! (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED))) {
        /* Mark as detached */
        thread->state |= PERL_ITHR_DETACHED;
#ifdef WIN32
        /* Windows has no 'detach thread' function */
#else
        PERL_THREAD_DETACH(thread->thr);
#endif
    }
    cleanup = ((thread->state & PERL_ITHR_FINISHED) &&
               (thread->state & PERL_ITHR_DETACHED));
    MUTEX_UNLOCK(&thread->mutex);

    if (cleanup)
        Perl_ithread_destruct(aTHX_ thread);
}


int
Perl_ithread_hook(pTHX)
{
    int veto_cleanup = 0;
    MUTEX_LOCK(&create_destruct_mutex);
    if ((aTHX == PL_curinterp) && (active_threads > 1)) {
        if (ckWARN_d(WARN_THREADS)) {
            Perl_warn(aTHX_ "A thread exited while %" IVdf " threads were running", (IV)active_threads);
        }
        veto_cleanup = 1;
    }
    MUTEX_UNLOCK(&create_destruct_mutex);
    return (veto_cleanup);
}


/* MAGIC (in mg.h sense) hooks */

int
ithread_mg_get(pTHX_ SV *sv, MAGIC *mg)
{
    ithread *thread = (ithread *)mg->mg_ptr;
    SvIV_set(sv, PTR2IV(thread));
    SvIOK_on(sv);
    return (0);
}

int
ithread_mg_free(pTHX_ SV *sv, MAGIC *mg)
{
    int cleanup;

    ithread *thread = (ithread *)mg->mg_ptr;
    MUTEX_LOCK(&thread->mutex);
    cleanup = ((--thread->count == 0) &&
               (thread->state & PERL_ITHR_FINISHED) &&
               (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)));
    MUTEX_UNLOCK(&thread->mutex);

    if (cleanup)
        Perl_ithread_destruct(aTHX_ thread);
    return (0);
}

int
ithread_mg_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    ithread *thread = (ithread *)mg->mg_ptr;
    MUTEX_LOCK(&thread->mutex);
    thread->count++;
    MUTEX_UNLOCK(&thread->mutex);
    return (0);
}

MGVTBL ithread_vtbl = {
    ithread_mg_get,     /* get */
    0,                  /* set */
    0,                  /* len */
    0,                  /* clear */
    ithread_mg_free,    /* free */
    0,                  /* copy */
    ithread_mg_dup      /* dup */
};


/* Type conversion helper functions */
static SV *
ithread_to_SV(pTHX_ SV *obj, ithread *thread, char *classname, bool inc)
{
    SV *sv;
    MAGIC *mg;
    if (inc) {
        MUTEX_LOCK(&thread->mutex);
        thread->count++;
        MUTEX_UNLOCK(&thread->mutex);
    }
    if (! obj) {
        obj = newSV(0);
    }
    sv = newSVrv(obj, classname);
    sv_setiv(sv, PTR2IV(thread));
    mg = sv_magicext(sv, Nullsv, PERL_MAGIC_shared_scalar, &ithread_vtbl, (char *)thread, 0);
    mg->mg_flags |= MGf_DUP;
    SvREADONLY_on(sv);
    return (obj);
}

static ithread *
SV_to_ithread(pTHX_ SV *sv)
{
    if (SvROK(sv)) {
      return (INT2PTR(ithread *, SvIV(SvRV(sv))));
    }
    return (Perl_ithread_get(aTHX));
}


/* Provided default, minimum and rational stack sizes */
static UV
good_stack_size(pTHX_ ithread *thread, UV stack_size)
{
    /* Use default stack size if no stack size specified */
    if (! stack_size)
        return (default_stack_size);

#ifdef PTHREAD_STACK_MIN
    /* Can't use less than minimum */
    if (stack_size < PTHREAD_STACK_MIN) {
        if (ckWARN_d(WARN_THREADS)) {
            Perl_warn(aTHX_ "Using minimum thread stack size of %" UVuf, (UV)PTHREAD_STACK_MIN);
        }
        return (PTHREAD_STACK_MIN);
    }
#endif

    /* Round up to page size boundary */
    if (page_size <= 0) {
#ifdef PL_mmap_page_size
        page_size = PL_mmap_page_size;
#else
#  ifdef HAS_MMAP
#    if defined(HAS_SYSCONF) && (defined(_SC_PAGESIZE) || defined(_SC_MMAP_PAGE_SIZE))
        SETERRNO(0, SS_NORMAL);
#      ifdef _SC_PAGESIZE
        page_size = sysconf(_SC_PAGESIZE);
#      else
        page_size = sysconf(_SC_MMAP_PAGE_SIZE);
#      endif
        if ((long)page_size < 0) {
            if (errno) {
                SV * const error = get_sv("@", FALSE);
                (void)SvUPGRADE(error, SVt_PV);
                Perl_croak(aTHX_ "PANIC: sysconf: %s", SvPV_nolen(error));
            } else {
                Perl_croak(aTHX_ "PANIC: sysconf: pagesize unknown");
            }
        }
#    else
#      ifdef HAS_GETPAGESIZE
        page_size = getpagesize();
#      else
#        if defined(I_SYS_PARAM) && defined(PAGESIZE)
        page_size = PAGESIZE;
#        endif
#      endif
        if (page_size <= 0)
            Perl_croak(aTHX_ "PANIC: bad pagesize %" IVdf, (IV)page_size);
#    endif
#  else
        page_size = 8192;   /* A conservative default */
#  endif
#endif
    }
    stack_size = ((stack_size + (page_size - 1)) / page_size) * page_size;

    return (stack_size);
}


/* Starts executing the thread.
 * Passed as the C level function to run in the new thread.
 */
#ifdef WIN32
static THREAD_RET_TYPE
Perl_ithread_run(LPVOID arg)
#else
static void *
Perl_ithread_run(void * arg)
#endif
{
    ithread *thread = (ithread *)arg;
    int cleanup;

    dTHXa(thread->interp);
    PERL_SET_CONTEXT(thread->interp);
    Perl_ithread_set(aTHX_ thread);

    PL_perl_destruct_level = 2;

    {
        AV *params = (AV *)SvRV(thread->params);
        IV len = av_len(params)+1;
        int i;

        dSP;
        ENTER;
        SAVETMPS;

        /* Put args on the stack */
        PUSHMARK(SP);
        for (i=0; i < len; i++) {
            XPUSHs(av_shift(params));
        }
        PUTBACK;

        /* Run the specified function */
        len = call_sv(thread->init_function, thread->gimme|G_EVAL);

        /* Remove args from stack and put back in params array */
        SPAGAIN;
        for (i=len-1; i >= 0; i--) {
          SV *sv = POPs;
          av_store(params, i, SvREFCNT_inc(sv));
        }

        /* Check for failure */
        if (SvTRUE(ERRSV) && ckWARN_d(WARN_THREADS)) {
            Perl_warn(aTHX_ "Thread failed to start: %" SVf, ERRSV);
        }

        FREETMPS;
        LEAVE;
    }

    PerlIO_flush((PerlIO *)NULL);

    MUTEX_LOCK(&thread->mutex);
    /* Mark as finished */
    thread->state |= PERL_ITHR_FINISHED;
    /* Cleanup if detached */
    cleanup = (thread->state & PERL_ITHR_DETACHED);
    MUTEX_UNLOCK(&thread->mutex);

    if (cleanup)
        Perl_ithread_destruct(aTHX_ thread);

    MUTEX_LOCK(&create_destruct_mutex);
    active_threads--;
    MUTEX_UNLOCK(&create_destruct_mutex);

#ifdef WIN32
    return ((DWORD)0);
#else
    return (0);
#endif
}


/* threads->create()
 * Called in context of parent thread.
 */
static SV *
Perl_ithread_create(
        pTHX_ SV *obj,
        char     *classname,
        SV       *init_function,
        UV        stack_size,
        SV       *params)
{
    ithread     *thread;
    CLONE_PARAMS clone_param;
    ithread     *current_thread = Perl_ithread_get(aTHX);

    SV         **tmps_tmp = PL_tmps_stack;
    IV           tmps_ix  = PL_tmps_ix;
#ifndef WIN32
    int          rc_thread_create = 0;
    int          rc_stack_size = 0;
#endif

    MUTEX_LOCK(&create_destruct_mutex);

    thread = (ithread *)PerlMemShared_malloc(sizeof(ithread));
    if (!thread) {
        MUTEX_UNLOCK(&create_destruct_mutex);
        PerlLIO_write(PerlIO_fileno(Perl_error_log), PL_no_mem, strlen(PL_no_mem));
        my_exit(1);
    }
    Zero(thread, 1 ,ithread);

    /* Add to threads list */
    thread->next = threads;
    thread->prev = threads->prev;
    threads->prev = thread;
    thread->prev->next = thread;

    /* Set count to 1 immediately in case thread exits before
     * we return to caller!
     */
    thread->count = 1;

    MUTEX_INIT(&thread->mutex);
    thread->tid = tid_counter++;
    thread->stack_size = good_stack_size(aTHX_ current_thread, stack_size);
    thread->gimme = GIMME_V;

    /* "Clone" our interpreter into the thread's interpreter.
     * This gives thread access to "static data" and code.
     */
    PerlIO_flush((PerlIO *)NULL);
    Perl_ithread_set(aTHX_ thread);

    SAVEBOOL(PL_srand_called); /* Save this so it becomes the correct value */
    PL_srand_called = FALSE;   /* Set it to false so we can detect if it gets
                                  set during the clone */

#ifdef WIN32
    thread->interp = perl_clone(aTHX, CLONEf_KEEP_PTR_TABLE | CLONEf_CLONE_HOST);
#else
    thread->interp = perl_clone(aTHX, CLONEf_KEEP_PTR_TABLE);
#endif
    thread->free_interp = thread->interp;

    /* perl_clone() leaves us in new interpreter's context.  As it is tricky
     * to spot an implicit aTHX, create a new scope with aTHX matching the
     * context for the duration of our work for new interpreter.
     */
    {
        dTHXa(thread->interp);

        MY_CXT_CLONE;

        /* Here we remove END blocks since they should only run in the thread
         * they are created
         */
        SvREFCNT_dec(PL_endav);
        PL_endav = newAV();
        clone_param.flags = 0;
        thread->init_function = sv_dup(init_function, &clone_param);
        if (SvREFCNT(thread->init_function) == 0) {
            SvREFCNT_inc(thread->init_function);
        }

        thread->params = sv_dup(params, &clone_param);
        SvREFCNT_inc(thread->params);

        /* The code below checks that anything living on the tmps stack and
         * has been cloned (so it lives in the ptr_table) has a refcount
         * higher than 0.
         *
         * If the refcount is 0 it means that a something on the stack/context
         * was holding a reference to it and since we init_stacks() in
         * perl_clone that won't get cleaned and we will get a leaked scalar.
         * The reason it was cloned was that it lived on the @_ stack.
         *
         * Example of this can be found in bugreport 15837 where calls in the
         * parameter list end up as a temp.
         *
         * One could argue that this fix should be in perl_clone.
         */
        while (tmps_ix > 0) {
            SV* sv = (SV*)ptr_table_fetch(PL_ptr_table, tmps_tmp[tmps_ix]);
            tmps_ix--;
            if (sv && SvREFCNT(sv) == 0) {
                SvREFCNT_inc(sv);
                SvREFCNT_dec(sv);
            }
        }

        SvTEMP_off(thread->init_function);
        ptr_table_free(PL_ptr_table);
        PL_ptr_table = NULL;
        PL_exit_flags |= PERL_EXIT_DESTRUCT_END;
    }
    Perl_ithread_set(aTHX_ current_thread);
    PERL_SET_CONTEXT(aTHX);

    /* Create/start the thread */
#ifdef WIN32
    thread->handle = CreateThread(NULL,
                                  thread->stack_size,
                                  Perl_ithread_run,
                                  (LPVOID)thread,
                                  STACK_SIZE_PARAM_IS_A_RESERVATION,
                                  &thread->thr);
#else
    {
        static pthread_attr_t attr;
        static int attr_inited = 0;
        static int attr_joinable = PTHREAD_CREATE_JOINABLE;
        if (! attr_inited) {
            pthread_attr_init(&attr);
            attr_inited = 1;
        }

#  ifdef PTHREAD_ATTR_SETDETACHSTATE
        /* Threads start out joinable */
        PTHREAD_ATTR_SETDETACHSTATE(&attr, attr_joinable);
#  endif

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
        /* Set thread's stack size */
        if (thread->stack_size > 0) {
            rc_stack_size = pthread_attr_setstacksize(&attr, thread->stack_size);
        }
#  endif

        /* Create the thread */
        if (! rc_stack_size) {
#  ifdef OLD_PTHREADS_API
            rc_thread_create = pthread_create(&thread->thr,
                                              attr,
                                              Perl_ithread_run,
                                              (void *)thread);
#  else
#    if defined(HAS_PTHREAD_ATTR_SETSCOPE) && defined(PTHREAD_SCOPE_SYSTEM)
            pthread_attr_setscope(&attr, PTHREAD_SCOPE_SYSTEM);
#    endif
            rc_thread_create = pthread_create(&thread->thr,
                                              &attr,
                                              Perl_ithread_run,
                                              (void *)thread);
#  endif
        }

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
        /* Try to get thread's actual stack size */
        {
            size_t stacksize;
            if (! pthread_attr_getstacksize(&attr, &stacksize)) {
                if (stacksize) {
                    thread->stack_size = (UV)stacksize;
                }
            }
        }
#  endif
    }
#endif

    /* Check for errors */
#ifdef WIN32
    if (thread->handle == NULL) {
#else
    if (rc_thread_create || rc_stack_size) {
#endif
        MUTEX_UNLOCK(&create_destruct_mutex);
        sv_2mortal(params);
        Perl_ithread_destruct(aTHX_ thread);
#ifndef WIN32
        if (ckWARN_d(WARN_THREADS)) {
            if (rc_stack_size)
                Perl_warn(aTHX_ "Thread creation failed: pthread_attr_setstacksize(%" UVuf ") returned %d", thread->stack_size, rc_stack_size);
            else if (rc_thread_create && ckWARN_d(WARN_THREADS))
                Perl_warn(aTHX_ "Thread creation failed: pthread_create returned %d", rc_thread_create);
        }
#endif
        return (&PL_sv_undef);
    }

    active_threads++;
    MUTEX_UNLOCK(&create_destruct_mutex);

    sv_2mortal(params);

    return (ithread_to_SV(aTHX_ obj, thread, classname, FALSE));
}


/* Return the current thread's object */
static SV *
Perl_ithread_self(pTHX_ SV *obj, char* classname)
{
    ithread *thread = Perl_ithread_get(aTHX);
    return (ithread_to_SV(aTHX_ obj, thread, classname, TRUE));
}


/* Joins the thread.
 * This code takes the return value from the call_sv and sends it back.
 */
static AV *
Perl_ithread_join(pTHX_ SV *obj)
{
    ithread *thread = SV_to_ithread(aTHX_ obj);
    int join_err;
    AV *retparam;
#ifdef WIN32
    DWORD waitcode;
#else
    void *retval;
#endif

    MUTEX_LOCK(&thread->mutex);
    join_err = (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED));
    MUTEX_UNLOCK(&thread->mutex);

    if (join_err) {
        if (join_err & PERL_ITHR_DETACHED) {
            Perl_croak(aTHX_ "Cannot join a detached thread");
        } else {
            Perl_croak(aTHX_ "Thread already joined");
        }
    }

#ifdef WIN32
    waitcode = WaitForSingleObject(thread->handle, INFINITE);
#else
    pthread_join(thread->thr, &retval);
#endif

    MUTEX_LOCK(&thread->mutex);

    /* sv_dup over the args */
    {
        AV *params;
        PerlInterpreter *other_perl;
        CLONE_PARAMS clone_params;
        ithread *current_thread;

        params = (AV *)SvRV(thread->params);
        other_perl = thread->interp;
        clone_params.stashes = newAV();
        clone_params.flags = CLONEf_JOIN_IN;
        PL_ptr_table = ptr_table_new();
        current_thread = Perl_ithread_get(aTHX);
        Perl_ithread_set(aTHX_ thread);
        /* Ensure 'meaningful' addresses retain their meaning */
        ptr_table_store(PL_ptr_table, &other_perl->Isv_undef, &PL_sv_undef);
        ptr_table_store(PL_ptr_table, &other_perl->Isv_no, &PL_sv_no);
        ptr_table_store(PL_ptr_table, &other_perl->Isv_yes, &PL_sv_yes);
        retparam = (AV *)sv_dup((SV*)params, &clone_params);
        Perl_ithread_set(aTHX_ current_thread);
        SvREFCNT_dec(clone_params.stashes);
        SvREFCNT_inc(retparam);
        ptr_table_free(PL_ptr_table);
        PL_ptr_table = NULL;
    }

    /* We are finished with it */
    thread->state |= PERL_ITHR_JOINED;
    S_ithread_clear(aTHX_ thread);
    MUTEX_UNLOCK(&thread->mutex);

    return (retparam);
}


static void
Perl_ithread_DESTROY(pTHX_ SV *sv)
{
    ithread *thread = SV_to_ithread(aTHX_ sv);
    sv_unmagic(SvRV(sv), PERL_MAGIC_shared_scalar);
}

#endif /* USE_ITHREADS */

MODULE = threads    PACKAGE = threads    PREFIX = ithread_
PROTOTYPES: DISABLE

#ifdef USE_ITHREADS

void
ithread_create(...)
    PREINIT:
        char *classname;
        ithread *thread;
        SV *function_to_call;
        AV *params;
        HV *specs;
        UV stack_size;
        int idx;
        int ii;
    CODE:
        if ((items >= 2) && SvROK(ST(1)) && SvTYPE(SvRV(ST(1)))==SVt_PVHV) {
            if (--items < 2)
                Perl_croak(aTHX_ "Usage: threads->create(\\%specs, function, ...)");
            specs = (HV*)SvRV(ST(1));
            idx = 1;
        } else {
            if (items < 2)
                Perl_croak(aTHX_ "Usage: threads->create(function, ...)");
            specs = NULL;
            idx = 0;
        }

        if (sv_isobject(ST(0))) {
            /* $thr->create() */
            classname = HvNAME(SvSTASH(SvRV(ST(0))));
            thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            stack_size = thread->stack_size;
        } else {
            /* threads->create() */
            classname = (char *)SvPV_nolen(ST(0));
            stack_size = default_stack_size;
        }

        function_to_call = ST(idx+1);

        if (specs) {
            /* stack_size */
            if (hv_exists(specs, "stack", 5)) {
                stack_size = SvUV(*hv_fetch(specs, "stack", 5, 0));
            } else if (hv_exists(specs, "stacksize", 9)) {
                stack_size = SvUV(*hv_fetch(specs, "stacksize", 9, 0));
            } else if (hv_exists(specs, "stack_size", 10)) {
                stack_size = SvUV(*hv_fetch(specs, "stack_size", 10, 0));
            }
        }

        /* Function args */
        params = newAV();
        if (items > 2) {
            for (ii=2; ii < items ; ii++) {
                av_push(params, SvREFCNT_inc(ST(idx+ii)));
            }
        }

        /* Create thread */
        ST(0) = sv_2mortal(Perl_ithread_create(aTHX_ Nullsv,
                                               classname,
                                               function_to_call,
                                               stack_size,
                                               newRV_noinc((SV*)params)));
        /* XSRETURN(1); - implied */


void
ithread_self(...)
    PREINIT:
        char *classname;
    CODE:
        /* Class method only */
        if (SvROK(ST(0)))
            Perl_croak(aTHX_ "Usage: threads->self()");
        classname = (char *)SvPV_nolen(ST(0));

        ST(0) = sv_2mortal(Perl_ithread_self(aTHX_ Nullsv, classname));
        /* XSRETURN(1); - implied */


void
ithread_tid(...)
    PREINIT:
        ithread *thread;
    CODE:
        thread = SV_to_ithread(aTHX_ ST(0));
        ST(0) = sv_2mortal(newSVuv(thread->tid));
        /* XSRETURN(1); - implied */


void
ithread__handle(...);
    PREINIT:
        ithread *thread;
    CODE:
        thread = SV_to_ithread(aTHX_ ST(0));
#ifdef WIN32
        ST(0) = sv_2mortal(newSVuv(PTR2UV(thread->handle)));
#else
        ST(0) = sv_2mortal(newSVuv(PTR2UV(thread->thr)));
#endif
        /* XSRETURN(1); - implied */


void
ithread_join(...)
    PREINIT:
        AV *params;
        IV len;
        int i;
    PPCODE:
        /* Object method only */
        if (! sv_isobject(ST(0)))
            Perl_croak(aTHX_ "Usage: $thr->join()");

        /* Join thread and get return values */
        params = Perl_ithread_join(aTHX_ ST(0));
        if (! params) {
            XSRETURN_UNDEF;
        }
        len = AvFILL(params);
        /* Put return values on stack */
        for (i=0; i <= len; i++) {
            SV* tmp = av_shift(params);
            XPUSHs(tmp);
            sv_2mortal(tmp);
        }
        /* Free return value array */
        SvREFCNT_dec(params);


void
ithread_detach(...)
    PREINIT:
        ithread *thread;
    CODE:
        thread = SV_to_ithread(aTHX_ ST(0));
        Perl_ithread_detach(aTHX_ thread);


void
ithread_DESTROY(...)
    CODE:
        Perl_ithread_DESTROY(aTHX_ ST(0));


void
ithread_list(...)
    PREINIT:
        char *classname;
        ithread *thr;
        int list_context;
        IV count = 0;
    PPCODE:
        /* Class method only */
        if (SvROK(ST(0)))
            Perl_croak(aTHX_ "Usage: threads->list()");
        classname = (char *)SvPV_nolen(ST(0));

        /* Calling context */
        list_context = (GIMME_V == G_ARRAY);

        /* Walk through threads list */
        MUTEX_LOCK(&create_destruct_mutex);
        for (thr = threads->next;
             thr != threads;
             thr = thr->next)
        {
            /* Ignore detached or joined threads */
            if (thr->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)) {
                continue;
            }
            /* Push object on stack if list context */
            if (list_context) {
                XPUSHs(sv_2mortal(ithread_to_SV(aTHX_ NULL, thr, classname, TRUE)));
            }
            count++;
        }
        MUTEX_UNLOCK(&create_destruct_mutex);
        /* If scalar context, send back count */
        if (! list_context) {
            ST(0) = sv_2mortal(newSViv(count));
            XSRETURN(1);
        }


void
ithread_object(...)
    PREINIT:
        char *classname;
        UV tid;
        ithread *thr;
        int found = 0;
    CODE:
        /* Class method only */
        if (SvROK(ST(0)))
            Perl_croak(aTHX_ "Usage: threads->object($tid)");
        classname = (char *)SvPV_nolen(ST(0));

        if ((items < 2) || ! SvOK(ST(1))) {
            XSRETURN_UNDEF;
        }

        tid = (UV)SvUV(ST(1));

        /* Walk through threads list */
        MUTEX_LOCK(&create_destruct_mutex);
        for (thr = threads->next;
             thr != threads;
             thr = thr->next)
        {
            /* Look for TID, but ignore detached or joined threads */
            if ((thr->tid != tid) ||
                (thr->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)))
            {
                continue;
            }
            /* Put object on stack */
            ST(0) = sv_2mortal(ithread_to_SV(aTHX_ NULL, thr, classname, TRUE));
            found = 1;
            break;
        }
        MUTEX_UNLOCK(&create_destruct_mutex);
        if (! found) {
            XSRETURN_UNDEF;
        }
        /* XSRETURN(1); - implied */


void
ithread_get_stack_size(...)
    PREINIT:
        UV stack_size;
    CODE:
        if (sv_isobject(ST(0))) {
            /* $thr->get_stack_size() */
            ithread *thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            stack_size = thread->stack_size;
        } else {
            /* threads->get_stack_size() */
            stack_size = default_stack_size;
        }
        ST(0) = sv_2mortal(newSVuv(stack_size));
        /* XSRETURN(1); - implied */


void
ithread_set_stack_size(...)
    PREINIT:
        UV old_size;
    CODE:
        if (items != 2)
            Perl_croak(aTHX_ "Usage: threads->set_stack_size($size)");
        if (sv_isobject(ST(0)))
            Perl_croak(aTHX_ "Cannot change stack size of an existing thread");

        old_size = default_stack_size;
        default_stack_size = good_stack_size(aTHX_ Perl_ithread_get(aTHX), SvUV(ST(1)));
        ST(0) = sv_2mortal(newSVuv(old_size));
        /* XSRETURN(1); - implied */


void
ithread_yield(...)
    CODE:
        YIELD;


void
ithread_equal(...)
    CODE:
        if (sv_isobject(ST(0)) && sv_isobject(ST(1))) {
            ithread *thr1 = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            ithread *thr2 = INT2PTR(ithread *, SvIV(SvRV(ST(1))));
            ST(0) = (thr1->tid == thr2->tid) ? &PL_sv_yes : &PL_sv_no;
        } else {
            ST(0) = &PL_sv_no;
        }
        /* XSRETURN(1); - implied */

#endif /* USE_ITHREADS */

BOOT:
{
#ifdef USE_ITHREADS
    /* The 'main' thread is thread 0.
     * It is detached (unjoinable) and immortal.
     */

    ithread *thread;
    MY_CXT_INIT;

    PL_perl_destruct_level = 2;
    MUTEX_INIT(&create_destruct_mutex);
    MUTEX_LOCK(&create_destruct_mutex);

    PL_threadhook = &Perl_ithread_hook;

    thread = (ithread *)PerlMemShared_malloc(sizeof(ithread));
    if (! thread) {
        PerlLIO_write(PerlIO_fileno(Perl_error_log), PL_no_mem, strlen(PL_no_mem));
        my_exit(1);
    }
    Zero(thread, 1, ithread);

    PL_perl_destruct_level = 2;
    MUTEX_INIT(&thread->mutex);

    thread->tid = tid_counter++;        /* Thread 0 */

    /* Head of the threads list */
    threads = thread;
    thread->next = thread;
    thread->prev = thread;

    thread->count = 1;                  /* Immortal */

    thread->interp = aTHX;
    thread->free_interp = aTHX;
    thread->state = PERL_ITHR_DETACHED; /* Detached */
    thread->stack_size = default_stack_size;
#  ifdef WIN32
    thread->thr = GetCurrentThreadId();
#  else
    thread->thr = pthread_self();
#  endif

    active_threads++;

    Perl_ithread_set(aTHX_ thread);
    MUTEX_UNLOCK(&create_destruct_mutex);
#endif /* USE_ITHREADS */
}
