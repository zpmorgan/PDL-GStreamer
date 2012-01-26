
use Modern::Perl;
use lib 'lib';
use PDL;
use PDL::Graphics2D 'imag2d';
use PDL::GStreamer;

use File::Spec;
my $filename = shift @ARGV;
die 'nofile' unless $filename;
$filename = File::Spec->rel2abs($filename);
die 'notfound' unless -e $filename;

my $tune = PDL::GStreamer->new(
   filename => $filename,
   do_video => 0,
);
#$tune->seek(10);

my ($audio,$format) = $tune->capture_audio(1);

#die $audio->dims;

my $rawsound = pack ($format->{packtemplate} .'*' , $audio->slice('0')->list);
my $pa;
open ($pa,'|pacat --format=s16le --channels=1');
print $pa $rawsound;
close($pa);
