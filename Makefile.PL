use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'Apache::Centipaid',
    'VERSION_FROM' => 'Centipaid.pm', # finds $VERSION
    dist => {
	SUFFIX => 'gz',
	COMPRESS => 'gzip -9',
    }
);
