package threads;

use 5.008;

use strict;
use warnings;

our $VERSION = '1.09';

BEGIN {
    # Verify this Perl supports threads
    use Config;
    if (! $Config{useithreads}) {
        die("This Perl not built to support threads\n");
    }

    # Complain if 'threads' is loaded after 'threads::shared'
    if ($threads::shared::threads_shared) {
        warn <<'_MSG_';
Warning, threads::shared has already been loaded.  To
enable shared variables, 'use threads' must be called
before threads::shared or any module that uses it.
_MSG_
   }
}


# Load the XS code
require XSLoader;
XSLoader::load('threads', $VERSION);

$threads::threads = 1;


### Export ###

sub import
{
    my $class = shift;   # Not used

    # Exported subroutines
    my @EXPORT = qw(async);

    # Handle args
    while (my $sym = shift) {
        if ($sym =~ /^stack/) {
            threads->set_stack_size(shift);

        } elsif ($sym eq 'all') {
            push(@EXPORT, qw(yield));

        } else {
            push(@EXPORT, $sym);
        }
    }

    # Export subroutine names
    my $caller = caller();
    foreach my $sym (@EXPORT) {
        no strict 'refs';
        *{$caller.'::'.$sym} = \&{$sym};
    }

    # Set stack size via environment variable
    if (exists($ENV{'PERL5_ITHREADS_STACK_SIZE'})) {
        threads->set_stack_size($ENV{'PERL5_ITHREADS_STACK_SIZE'});
    }
}


### Methods, etc. ###

# 'new' is an alias for 'create'
*new = \&create;

# 'async' is a function alias for the 'threads->create()' method
sub async (&;@)
{
    unshift(@_, 'threads');
    # Use "goto" trick to avoid pad problems from 5.8.1 (fixed in 5.8.2)
    goto &create;
}

# Thread object method for checking equality against another thread object
sub equal {
    return (($_[0]->tid == $_[1]->tid) || 0);   # || 0 to ensure compatibility
                                                # with previous versions
}

# Overload '==' for checking thread object equality
use overload (
    '=='       => \&equal,
    'fallback' => 1
);

1;

__END__

=head1 NAME

threads - Perl interpreter-based threads

=head1 VERSION

This document describes threads version 1.09

=head1 SYNOPSIS

    use threads ('yield', 'stack_size' => 1_000_000);

    sub start_thread {
        my @args = @_;
        print "Thread started: @args\n";
    }
    my $thread = threads->create('start_thread', 'argument');
    $thread->join();

    threads->create(sub { print("I am a thread\n"); })->join();

    my $thread3 = async { foreach (@files) { ... } };
    $thread3->join();

    # Invoking thread in list context so it can return a list
    my ($thr) = threads->create(sub { return (qw/a b c/); });
    my @results = $thr->join();

    $thread->detach();

    $thread = threads->self();
    $thread = threads->object($tid);

    $tid = threads->tid();
    $tid = threads->self->tid();
    $tid = $thread->tid();

    threads->yield();
    yield();

    my @threads = threads->list();
    my $thread_count = threads->list();

    if ($thr1 == $thr2) {
        ...
    }

    $stack_size = threads->get_stack_size();
    $old_size = threads->set_stack_size(2_000_000);

=head1 DESCRIPTION

Perl 5.6 introduced something called interpreter threads.  Interpreter threads
are different from I<5005threads> (the thread model of Perl 5.005) by creating
a new Perl interpreter per thread, and not sharing any data or state between
threads by default.

Prior to Perl 5.8, this has only been available to people embedding Perl, and
for emulating fork() on Windows.

The I<threads> API is loosely based on the old Thread.pm API. It is very
important to note that variables are not shared between threads, all variables
are by default thread local.  To use shared variables one must use
L<threads::shared>.

It is also important to note that you must enable threads by doing C<use
threads> as early as possible in the script itself, and that it is not
possible to enable threading inside an C<eval "">, C<do>, C<require>, or
C<use>.  In particular, if you are intending to share variables with
L<threads::shared>, you must C<use threads> before you C<use threads::shared>.
(C<threads> will emit a warning if you do it the other way around.)

=over

=item $thread = threads->create(FUNCTION, ARGS)

This will create a new thread with the entry point function, and give
it the I<ARGS> list as parameters.  It will return the corresponding threads
object, or C<undef> if thread creation failed.  The C<-E<gt>new()> method is
an alias for C<-E<gt>create()>.

I<FUNCTION> may either be the name of a function, an anonymous subroutine, or
a code ref.

    my $thr = threads->create('func_name', ...);
        # or
    my $thr = threads->create(sub { ... }, ...);
        # or
    my $thr = threads->create(\&func, ...);

=item $thread->join()

This will wait for the corresponding thread to join. When the thread
finishes, C<-E<gt>join()> will return the return values of the entry point
function. If the thread has been detached, an error will be thrown.

The context (void, scalar or list) of the thread creation is also the
context for C<-E<gt>join()>.  This means that if you intend to return an array
from a thread, you must use C<my ($thread) = threads->create(...)>, and that
if you intend to return a scalar, you must use C<my $thread = ...>.

If the program exits without all other threads having been either joined or
detached, then a warning will be issued. (A program exits either because one
of its threads explicitly calls exit(), or in the case of the main thread,
reaches the end of the main program file.)

=item $thread->detach()

Makes the thread unjoinable, and causes any eventual return value to be
discarded.

=item threads->self()

This will return the threads object for the current thread.

=item $thread->tid()

This will return the ID of the thread.  Thread IDs are integers, with
the main thread in a program being 0.  Currently, Perl assigns a unique
TID to every thread ever created in your program, assigning the first
thread to be created a TID of 1, and increasing the TID by 1 for each
new thread that's created.

N.B., the class method C<< threads->tid() >> is a quick way to get the
current thread id if you don't have your thread object handy.

=item threads->object($tid)

This will return the thread object for the thread associated with the
specified C<$tid>.  Returns undef if there is no thread associated with the
TID or no TID is specified or the specified TID is undef.

=item threads->yield();

This is a suggestion to the OS to let this thread yield CPU time to other
threads.  What actually happens is highly dependent upon the underlying
thread implementation.

You may do C<use threads qw(yield)>, and then use just a bare C<yield> in your
code.

=item threads->list();

In a list context, this returns a list of all non-joined, non-detached
threads.  In a scalar context, returns a count of the same.

=item $thr1->equal($thr2);

Tests if two threads objects are the same thread or not.  This is overloaded
to the more natural form:

    if ($thr1 == $thr2) {
        print("Threads are the same\n");
    }

(Thread comparison is based on thread IDs.)

=item async BLOCK;

C<async> creates a thread to execute the block immediately following
it.  This block is treated as an anonymous sub, and so must have a
semi-colon after the closing brace. Like C<< threads->create >>, C<async>
returns a thread object.

=item $thread->_handle()

This I<private> method returns the memory location of the internal thread
structure associated with a threads object.  For Win32, this is the handle
returned by C<CreateThread>; for other platforms, it is the pointer returned
by C<pthread_create>.

This method is of no use for general Perl threads programming.  Its intent is
to provide other (XS-based) thread modules with the capability to access, and
possibly manipulate, the underlying thread structure associated with a Perl
thread.

=back

=head1 THREAD STACK SIZE

The default per-thread stack size for different platforms varies
significantly, and is almost always far more than is needed for most
applications.  On Win32, Perl's makefile explicitly sets the default stack to
16 MB; on most other platforms, the system default is used, which again may be
much larger than is needed (e.g., the Linux default is around 8 MB).

By tuning the stack size to more accurately reflect your application's needs,
you may significantly reduce your application's memory usage, and increase the
number of simultaneously running threads.

N.B., on Windows, Address space allocation granularity is 64 KB, therefore,
setting the stack smaller than that on Win32 Perl will not save any more
memory.

=over

=item $size = threads->get_stack_size();

Gets the current default per-thread stack size.  The default is zero, which
means the system default stack size currently in use.

=item $size = $thr->get_stack_size();

Gets the stack size for a particular thread.  A return value of zero
indicates the system default stack size was used.

=item $old_size = threads->set_stack_size($new_size);

Sets a new default per-thread stack size, and returns the previous setting.
Threads created after the stack size is set will then either call
C<pthread_attr_setstacksize()> I<(for pthreads platforms)>, or supply the
stack size to C<CreateThread()> I<(for Win32 Perl)>.

(Obviously, this call does not affect any currently extant threads.)

=item use threads ('stack_size' => VALUE);

This sets the default per-thread stack size at the start of the application.

=item $ENV{'PERL5_ITHREADS_STACK_SIZE'}

The default per-thread stack size may be set at the start of the application
through the use of the environment variable C<PERL5_ITHREADS_STACK_SIZE>:

    PERL5_ITHREADS_STACK_SIZE=1000000
    export PERL5_ITHREADS_STACK_SIZE
    perl -e'use threads; print(threads->get_stack_size(), "\n")'

This value overrides any C<stack_size> parameter give to C<use threads>.  Its
primary purpose is to permit setting the per-thread stack size for legacy
threaded applications.

=item threads->create({'stack_size' => VALUE}, FUNCTION, ARGS)

This change to the thread creation method permits specifying the stack size
for an individual thread.

=item $thr2 = $thr1->create(FUNCTION, ARGS)

This creates a new thread (C<$thr2>) that inherits the stack size from an
existing thread (C<$thr1>).  This is shorthand for the following:

    my $stack_size = $thr1->get_stack_size();
    my $thr2 = threads->create({'stack_size' => $stack_size}, FUNCTION, ARGS);

=back

=head1 WARNINGS

=over 4

=item A thread exited while %d other threads were still running

A thread (not necessarily the main thread) exited while there were still other
threads running.  Usually it's a good idea to first collect the return values
of the created threads by joining them, and only then exit from the main
thread.

=back

=head1 ERRORS

=over 4

=item Cannot change stack size of an existing thread

The stack size of currently extant threads cannot be changed, therefore, the
following results in the above error:

    $thr->set_stack_size($size);

=item This Perl not built to support threads

The particular copy of Perl that you're trying to use was not built using the
C<useithreads> configuration option.

Having threads support requires all of Perl and all of the XS modules in the
Perl installation to be rebuilt; it is not just a question of adding the
L<threads> module (i.e., threaded and non-threaded Perls are binary
incompatible.)

=back

=head1 BUGS

=over

=item Parent-child threads

On some platforms, it might not be possible to destroy I<parent> threads while
there are still existing I<child> threads.

=item Returning objects

When you return an object, the entire stash that the object is blessed into is
returned as well.  This will lead to a large memory usage.  The ideal
situation would be to detect the original stash if it still exists.

=item Creating threads inside BEGIN blocks

Creating threads inside BEGIN blocks (or during the compilation phase in
general) does not work.  (In Windows, trying to use fork() inside BEGIN blocks
is an equally losing proposition, since it has been implemented in very much
the same way as threads.)

=item PERL_OLD_SIGNALS are not threadsafe, will not be.

If your Perl has been built with PERL_OLD_SIGNALS (one has to explicitly add
that symbol to I<ccflags>, see C<perl -V>), signal handling is not threadsafe.

=item Perl Bugs and the CPAN Version of L<threads>

Support for threads extents beyond the code in this module (i.e.,
F<threads.pm> and F<threads.xs>), and into the Perl iterpreter itself.  Older
versions of Perl contain bugs that may manifest themselves despite using the
latest version of L<threads> from CPAN.  There is no workaround for this other
than upgrading to the lastest version of Perl.

(Before you consider posting a bug report, please consult, and possibly post a
message to the discussion forum to see if what you've encountered is a known
problem.)

=back

View existing bug reports at, and submit any new bugs, problems, patches, etc.
to: L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=threads>

=head1 REQUIREMENTS

Perl 5.8.0 or later

=head1 SEE ALSO

L<threads> Discussion Forum on CPAN:
L<http://www.cpanforum.com/dist/threads>

Annotated POD for L<threads>:
L<http://annocpan.org/~JDHEDDEN/threads-1.09/shared.pm>

L<threads::shared>, L<perlthrtut>

L<http://www.perl.com/pub/a/2002/06/11/threads.html> and
L<http://www.perl.com/pub/a/2002/09/04/threads.html>

Perl threads mailing list:
L<http://lists.cpan.org/showlist.cgi?name=iThreads>

Stack size discussion:
L<http://www.perlmonks.org/?node_id=532956>

=head1 AUTHOR

Artur Bergman E<lt>sky AT crucially DOT netE<gt>

threads is released under the same license as Perl.

CPAN version produced by Jerry D. Hedden <jdhedden AT cpan DOT org>

=head1 ACKNOWLEDGEMENTS

Richard Soderberg E<lt>perl AT crystalflame DOT netE<gt> -
Helping me out tons, trying to find reasons for races and other weird bugs!

Simon Cozens E<lt>simon AT brecon DOT co DOT ukE<gt> -
Being there to answer zillions of annoying questions

Rocco Caputo E<lt>troc AT netrus DOT netE<gt>

Vipul Ved Prakash E<lt>mail AT vipul DOT netE<gt> -
Helping with debugging

Dean Arnold E<lt>darnold AT presicient DOT comE<gt> -
Stack size API

=cut
