use strict;
use warnings;

BEGIN {
    if ($ENV{'PERL_CORE'}){
        chdir 't';
        unshift @INC, '../lib';
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

sub skip {
    my $id = shift;
    ok(shift, 1, "# Skipped: @_");
}

BEGIN {
    $| = 1;
    print("1..14\n");   ### Number of tests that will be run ###
};

use threads;
use threads::shared;
ok(1, 1, 'Loaded');

### Start of Testing ###

my $test_id = 1;
share($test_id);

{
    my $retval = threads->create(sub { return ("hi") })->join();
    ok(++$test_id, $retval eq 'hi', "Check basic returnvalue");
}
{
    my ($thread) = threads->create(sub { return (1,2,3) });
    my @retval = $thread->join();
    ok(++$test_id, $retval[0] == 1 && $retval[1] == 2 && $retval[2] == 3,'');
}
{
    my $retval = threads->create(sub { return [1] })->join();
    ok(++$test_id, $retval->[0] == 1,"Check that a array ref works",);
}
{
    my $retval = threads->create(sub { return { foo => "bar" }})->join();
    ok(++$test_id, $retval->{foo} eq 'bar',"Check that hash refs work");
}
{
    my $retval = threads->create( sub {
        open(my $fh, "+>threadtest") || die $!;
        print $fh "test\n";
        return $fh;
    })->join();
    ok(++$test_id, ref($retval) eq 'GLOB', "Check that we can return FH $retval");
    print $retval "test2\n";
    close($retval);
    unlink("threadtest");
}
{
    my $test = "hi";
    my $retval = threads->create(sub { return $_[0]}, \$test)->join();
    ok(++$test_id, $$retval eq 'hi','');
}
{
    my $test = "hi";
    share($test);
    my $retval = threads->create(sub { return $_[0]}, \$test)->join();
    ok(++$test_id, $$retval eq 'hi','');
    $test = "foo";
    ok(++$test_id, $$retval eq 'foo','');
}
{
    my %foo;
    share(%foo);
    threads->create(sub { 
        my $foo;
        share($foo);
        $foo = "thread1";
        return $foo{bar} = \$foo;
    })->join();
    ok(++$test_id, 1,"");
}

# We parse ps output so this is OS-dependent.
if ($^O eq 'linux') {
    # First modify $0 in a subthread.
    #print "# mainthread: \$0 = $0\n";
    threads->create(sub{ #print "# subthread: \$0 = $0\n";
                        $0 = "foobar";
                        #print "# subthread: \$0 = $0\n"
                 })->join;
    #print "# mainthread: \$0 = $0\n";
    #print "# pid = $$\n";
    if (open PS, "ps -f |") { # Note: must work in (all) systems.
        my ($sawpid, $sawexe);
        while (<PS>) {
            chomp;
            #print "# [$_]\n";
            if (/^\s*\S+\s+$$\s/) {
                $sawpid++;
                if (/\sfoobar\s*$/) { # Linux 2.2 leaves extra trailing spaces.
                    $sawexe++;
                }
                last;
            }
        }
        close PS or die;
        if ($sawpid) {
            ok(++$test_id, $sawpid && $sawexe, 'altering $0 is effective');
        } else {
            skip(++$test_id, "\$0 check: did not see pid $$ in 'ps -f |'");
        }
    } else {
        skip(++$test_id,"\$0 check: opening 'ps -f |' failed: $!");
    }
} else {
    skip(++$test_id,"\$0 check: only on Linux");
}

{
    my $t = threads->create(sub {});
    $t->join;
    my $x = threads->create(sub {});
    $x->join;
    eval { $t->join; };
    ok(++$test_id, ($@ =~ /Thread already joined/), "Double join works");
}

{
    no warnings 'deprecated';

    # The "use IO" is not actually used for anything; its only purpose is to
    # incite a lot of calls to newCONSTSUB.  See the p5p archives for
    # the thread "maint@20974 or before broke mp2 ithreads test".
    use IO;
    $_->join for map threads->create(sub{ok(++$test_id, $_, "stress newCONSTSUB")}), 1..2;
}

# EOF
