#!/usr/bin/perl
use Modern::Perl;
use lib 'lib';
use PDL::GStreamer;
use PDL;
use PDL::Graphics2D 'imag2d';

#to run: ./screenshot_imag2d.pl blah.avi

my $filename = shift @ARGV;

my $noir = PDL::GStreamer->new(
   filename => $filename,
   #time => 500,
);
die unless $noir->check_video && $noir->check_audio;

$noir->seek(500); #seconds
my $screenshot = $noir->capture_image;
imag2d($screenshot);


