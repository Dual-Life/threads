use strict;
use warnings;

BEGIN {
    use Config;
    if (! $Config{'useithreads'}) {
        print("1..0 # Skip: Perl not compiled with 'useithreads'\n");
        exit(0);
    }
    if ($] <= 5.008) {
        print("1..0 # Skip: Requires Perl 5.8.1 or later\n");
        exit(0);
    }
}

use ExtUtils::testlib;

BEGIN {
    eval { require Perl; };
    if ($@) {
        print("1..0 # Skip: Perl.pm not available\n");
        exit(0);
    }

    $| = 1;
    print("1..16\n");
};

### Start of Testing ###

MAIN:
{
    # Save stdout/err
    no warnings 'once';
    open(ORIG_STDOUT,">&STDOUT");
    open(ORIG_STDERR,">&STDERR");

    my %perls;
    my $cnt = 1;
    foreach my $test (<t/*.t>) {
        # Skip some problematic test files
        next if ($test =~ /^t\/(?:embed|exit|kill|pod|thread)\.t$/);

        # Reopen stdout/err to /dev/null
        open(STDOUT, "+>/dev/null");
        open(STDERR, "+>&STDOUT");

        # Run the test file in a separate interpreter
        my $failure = 1;
        if ($perls{$test} = Perl->new('ARGV' => [ $test ])) {
            $failure = $perls{$test}->run();
        }

        # Restore stdout/err
        open(STDOUT, ">&ORIG_STDOUT");
        open(STDERR, ">&ORIG_STDERR");

        # Report results
        print('not ') if ($failure);
        print("ok $cnt - Test '$test'\n");
        $cnt++;
    }
}

# EOF
