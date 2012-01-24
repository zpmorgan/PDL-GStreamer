#!/usr/bin/perl
use Modern::Perl;
use lib 'lib';
use PDL::GStreamer;
use PDL;
use PDL::Graphics2D 'imag2d';

#to run: ./screenshot_imag2d.pl blah.avi

use File::Spec;
my $filename = shift @ARGV;
die 'nofile' unless $filename;
$filename = File::Spec->rel2abs($filename);
die 'notfound' unless -e $filename;

my $noir = PDL::GStreamer->new(
   filename => $filename,
);
die unless $noir->check_video && $noir->check_audio;

$noir->seek(732.8); #seconds
my $screenshot = $noir->capture_image;
imag2d($screenshot/256);

$noir->seek(rand(2200)); #seconds
$screenshot = $noir->capture_image;
imag2d($screenshot/256);

my ($sound,$format) = $noir->capture_audio(10);
#die $sound->dims;
#this isn't very portable.
#slice out the first channel.
my $rawsound = pack ($format->{packtemplate} .'*' , $sound->slice('0')->list);
my $pa;
open ($pa,'|pacat --format=s16le --channels=1');
print $pa $rawsound;
close($pa);

