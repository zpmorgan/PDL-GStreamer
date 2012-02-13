#!/usr/bin/env perl
use Modern::Perl;
use lib 'lib';
use PDL;
use PDL::Graphics2D 'imag2d';
use PDL::GStreamer;

my $g = PDL::GStreamer->new(
   filename => 'foo.avi',
   do_audio => 0,
   do_play => 0,
   scale_w => 32,
   scale_h => 32,
);

$g->seek(45);

my $img = $g->get_frame;
$img /= 256;
imag2d($img->reshape(3,$g->width,$g->height));

