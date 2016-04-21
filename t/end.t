use strict;
use warnings;

BEGIN {
    if (-d 't') {
        chdir('t');
    }
    if (-d '../lib') {
        push(@INC, '../lib');
    }
    use Config;
    if (! $Config{'useithreads'}) {
        print("1..0 # Skip: Perl not compiled with 'useithreads'\n");
        exit(0);
    }
}

use ExtUtils::testlib;

sub ok {
    my ($id, $ok, $name) = @_;

    # You have to do it this way or VMS will get confused.
    if ($ok) {
        print("ok $id - $name\n");
    } else {
        print("not ok $id - $name\n");
        printf("# Failed test at line %d\n", (caller)[2]);
    }

    return ($ok);
}

BEGIN {
    $| = 1;
    print("1..6\n");   ### Number of tests that will be run ###
};

use threads;
use threads::shared;
ok(1, 1, 'Loaded');

### Start of Testing ###

# Test that END blocks are run in the thread that created them,
# and not in any child threads.

my $test_id = 1;
share($test_id);

END {
    ok(++$test_id, 1, 'Main END block')
}

threads->create(sub { eval "END { ok(++\$test_id, 1, '1st thread END block') }"})->join();
threads->create(sub { eval "END { ok(++\$test_id, 1, '2nd thread END block') }"})->join();

sub thread {
    eval "END { ok(++\$test_id, 1, '4th thread END block') }";
    threads->create(sub { eval "END { ok(++\$test_id, 1, '5th thread END block') }"})->join();
}
threads->create(\&thread)->join();

# EOF
