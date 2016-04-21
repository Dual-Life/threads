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
    print("1..18\n");   ### Number of tests that will be run ###
};

use threads 1.09 ('stack_size' => 1_000_000);
ok(1, 1, 'Loaded');

### Start of Testing ###

ok(2, threads->get_stack_size() == 1_000_000,
        'Stack size set in import');
ok(3, threads->set_stack_size(2_000_000) == 1_000_000,
        'Set returns previous value');
ok(4, threads->get_stack_size() == 2_000_000,
        'Get stack size');

threads->create(
    sub {
        ok(5, threads->get_stack_size() == 2_000_000,
                'Get stack size in thread');
        ok(6, threads->self()->get_stack_size() == 2_000_000,
                'Thread gets own stack size');
        ok(7, threads->set_stack_size(1_000_000) == 2_000_000,
                'Thread changes stack size');
        ok(8, threads->get_stack_size() == 1_000_000,
                'Get stack size in thread');
        ok(9, threads->self()->get_stack_size() == 2_000_000,
                'Thread stack size unchanged');
    }
)->join();

ok(10, threads->get_stack_size() == 1_000_000,
        'Default thread sized changed in thread');

threads->create(
    { 'stack' => 2_000_000 },
    sub {
        ok(11, threads->get_stack_size() == 1_000_000,
                'Get stack size in thread');
        ok(12, threads->self()->get_stack_size() == 2_000_000,
                'Thread gets own stack size');
    }
)->join();

my $thr = threads->create( { 'stack' => 2_000_000 }, sub { } );

$thr->create(
    sub {
        ok(13, threads->get_stack_size() == 1_000_000,
                'Get stack size in thread');
        ok(14, threads->self()->get_stack_size() == 2_000_000,
                'Thread gets own stack size');
    }
)->join();

$thr->create(
    { 'stack' => 3_000_000 },
    sub {
        ok(15, threads->get_stack_size() == 1_000_000,
                'Get stack size in thread');
        ok(16, threads->self()->get_stack_size() == 3_000_000,
                'Thread gets own stack size');
        ok(17, threads->set_stack_size(2_000_000) == 1_000_000,
                'Thread changes stack size');
    }
)->join();

$thr->join();

ok(18, threads->get_stack_size() == 2_000_000,
        'Default thread sized changed in thread');

# EOF
