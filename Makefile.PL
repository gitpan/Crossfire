use ExtUtils::MakeMaker;

use Config;

my $mm = MM->new({
    dist         => {
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
    },
    PREREQ_PM   => {
       AnyEvent   => 0,
       JSON::Syck => 0.13,
    },
    NAME         => "Crossfire",
    VERSION_FROM => "Crossfire.pm",
    EXE_FILES    => [qw(bin/cfarch-normalize bin/cfmap-normalize bin/cfmap-plushify)],

});

$mm->flush;

