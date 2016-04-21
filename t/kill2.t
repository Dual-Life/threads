use strict;
use warnings;

BEGIN {
    require($ENV{PERL_CORE} ? '../../t/test.pl' : './t/test.pl');

    use Config;
    if (! $Config{'useithreads'}) {
        skip_all(q/Perl not compiled with 'useithreads'/);
    }
}

use ExtUtils::testlib;

use threads;

BEGIN {
    $| = 1;
    print("1..3\n");   ### Number of tests that will be run ###
};

fresh_perl_is(<<'EOI', 'ok', { }, 'No signal handler in thread');
    use threads;
    my $test = sub {
        while(1) { sleep(1) }
    };
    my $thr = threads->create($test);
    threads->yield();
    $thr->detach();
    eval {
        $thr->kill('STOP');
    };
    print(($@ =~ /no signal handler set/) ? 'ok' : 'not ok');
EOI

fresh_perl_is(<<'EOI', 'ok', { }, 'Handler to signal mismatch');
    use threads;
    my $test = sub {
        $SIG{'TERM'} = sub { threads->exit() };
        while(1) { sleep(1) }
    };
    my $thr = threads->create($test);
    threads->yield();
    $thr->detach();
    eval {
        $thr->kill('STOP');
    };
    print(($@ =~ /no signal handler set/) ? 'ok' : 'not ok');
EOI

fresh_perl_is(<<'EOI', 'ok', { }, 'Handler and signal match');
    use threads;
    my $test = sub {
        $SIG{'STOP'} = sub { threads->exit() };
        while(1) { sleep(1) }
    };
    my $thr = threads->create($test);
    threads->yield();
    $thr->detach();
    eval {
        $thr->kill('STOP');
    };
    print((! $@) ? 'ok' : 'not ok');
EOI

exit(0);

# EOF
