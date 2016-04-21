use strict;
use warnings;

BEGIN {
    eval {
        require Test::More;
        Test::More->import('tests' => 3);
    };
    if ($@) {
        print("1..0 # Skip: Test::More not available\n");
        exit(0);
    }
}

SKIP: {
    eval 'use Test::Pod 1.26';
    skip('Test::Pod 1.26 required for testing POD', 1) if $@;

    pod_file_ok('blib/lib/threads.pm');
}

SKIP: {
    eval 'use Test::Pod::Coverage 1.08';
    skip('Test::Pod::Coverage 1.08 required for testing POD coverage', 1) if $@;

    pod_coverage_ok('threads',
                    {
                        'trustme' => [
                            qr/^new$/,
                            qr/^exit$/,
                            qr/^async$/,
                            qr/^\(/,
                            qr/^(all|running|joinable)$/,
                        ],
                        'private' => [
                            qr/^import$/,
                            qr/^DESTROY$/,
                            qr/^bootstrap$/,
                        ]
                    }
    );
}

SKIP: {
    eval "use Test::Spelling";
    skip("Test::Spelling required for testing POD spelling", 1) if $@;
    set_spell_cmd('aspell -l --lang=en');
    add_stopwords(<DATA>);
    pod_file_spelling_ok('blib/lib/threads.pm', 'thread.pm spelling');
}

__DATA__

API
async
cpan
MSWin32
pthreads
SIGTERM
TID

Hedden
Soderberg
crystalflame
brecon
netrus
vipul
Ved
Prakash
presicient

okay
unjoinable

__END__
