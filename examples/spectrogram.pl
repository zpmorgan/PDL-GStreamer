#!/usr/bin/env perl
use Modern::Perl;
use lib 'lib';
use PDL;
use PDL::Graphics2D 'imag2d';
use PDL::Constants qw'PI I';
use PDL::GStreamer;
use PDL::FFTW;
use PDL::Complex;

my $do_play = 1;

use File::Spec;
my $filename = shift @ARGV;
die 'nofile' unless $filename;
$filename = File::Spec->rel2abs($filename);
die 'notfound' unless -e $filename;

my $tune = PDL::GStreamer->new(
   filename => $filename,
   do_video => 0,
);

#die $tune->duration;
#$tune->seek(10);

my $seconds = 28;
my ($audio,$format) = $tune->capture_audio($seconds);
 ($audio,$format) = $tune->capture_audio($seconds);

unless(!$do_play or fork()){
#die $audio->dims;
   my $rawsound = pack ($format->{packtemplate} .'*' , $audio->slice('0')->list);
   my $pa;
   open ($pa,'|pacat --format=s16le --channels=1');
   print $pa $rawsound unless fork();
   close($pa);
   exit;
}

my $ncols = 1000;

$audio = $audio->slice(0)->copy->squeeze;;
my $window_time = .04;
my $window_size = $window_time * $format->{rate};
my $sample_step = 2;

my $hann_window;
sub mk_hann_window{
   my $N = shift;
   $hann_window = sequence($N);
   $hann_window = .5 * (1 - cos(2 * PI * $hann_window / ($N-1)));
}

sub stfft{
   my $time = shift;
   $time *= $format->{rate};
   $time = int $time;
   my $window = $audio->slice($time.':'.($time+$window_size-1).':'.$sample_step)->sever;
   mk_hann_window($window->dim(0)) unless defined $hann_window;
   $window *= $hann_window;

   #make samples between -1 and 1.
   $window /= 1<<($format->{width}-1);
   $window -= 1;
   
   #fft & convert to polar.
   $window = cplx rfftw $window;
   return $window->Cr2p->real;
}
my $spectrogram;
for(0..$ncols-4){
   my $t = $_ * $seconds / $ncols;
   my $col = stfft($t)->dummy(1);
   unless(defined $spectrogram){
      $spectrogram = zeros(3,$ncols,$col->dim(2));
   }
   $spectrogram->slice("0:1,".$_) .= $col;
}
$spectrogram /= $spectrogram->slice(":,:,9:-1")->max;
imag2d($spectrogram);
