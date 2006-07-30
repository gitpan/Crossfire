use ExtUtils::MakeMaker;

use Config;

my $mm = MM->new({
    dist         => {
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
    },
    PREREQ_PM   => {
       JSON::Syck => 0.13,
    },
    NAME         => "Crossfire",
    VERSION_FROM => "Crossfire.pm",
    EXE_FILES    => ["bin/cfmap-normalize"],

});

$mm->flush;

