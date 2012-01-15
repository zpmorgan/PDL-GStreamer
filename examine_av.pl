#!/usr/bin/perl
use Modern::Perl;
use Glib qw/TRUE FALSE /;
use GStreamer qw/-init GST_TIME_FORMAT GST_SECOND/;

my $filename = shift @ARGV;
die 'nofile' unless $filename;

use Cwd 'abs_path';
$filename = abs_path $filename;
die 'notfound' unless -e $filename;

# frame positioning?
#
my $GST_SEEK_FLAG_ACCURATE = 1<<1;
my $player;
my $audio_sink;
my $video_sink;



# (from totem thumbnailer) /* our desired output format (RGB24) */
   #/* Note: we don't ask for a specific width/height here, so that
   #* videoscale can adjust dimensions from a non-1/1 pixel aspect
   #* ratio to a 1/1 pixel-aspect-ratio. We also don't ask for a
   #* specific framerate, because the input framerate won't
   #* necessarily match the output framerate if there's a deinterlacer
   #* in the pipeline. */
my $img_caps = GStreamer::Caps::Simple->new ("video/x-raw-rgb",
   "bpp", "Glib::Int", 24,
   "depth", 'Glib::Int', 24,
   "pixel-aspect-ratio", 'GStreamer::Fraction', [1, 1],
   #"endianness", 'Glib::Int', 'G_BIG_ENDIAN',
   "red_mask", 'Glib::Int', 0xff0000,
   "green_mask", 'Glib::Int', 0x00ff00,
   "blue_mask", 'Glib::Int', 0x0000ff,
);


# http://gstreamer.freedesktop.org/data/doc/gstreamer/head/manual/html/chapter-elements.html

sub setup_player{
   $player = GStreamer::ElementFactory -> make(playbin2 => "player");
   # http://git.gnome.org/browse/totem/tree/src/totem-video-thumbnailer.c
   # http://git.gnome.org/browse/totem/tree/src/gst/totem-gst-helpers.c
   $audio_sink = GStreamer::ElementFactory->make ("fakesink", "audio-fake-sink");
   $video_sink = GStreamer::ElementFactory->make ("fakesink", "video-fake-sink");
   #g_object_set (video_sink, "sync", TRUE, NULL);
   $video_sink->set("sync", TRUE);

   $player->set(
      "audio-sink" => $audio_sink,
      #   "video-sink" => $video_sink,
      #"flags" => [qw/ GST_PLAY_FLAG_VIDEO GST_PLAY_FLAG_AUDIO /],
   );
}

sub seek_to_random_frame{
   # actually seek to 500 seconds.
   my $foo = $player->seek (
      1, #rate
      "GST_FORMAT_TIME", #3, #format. GST_FORMAT_TIME(), #format
      "GST_SEEK_FLAG_ACCURATE", #flags
      "GST_SEEK_TYPE_SET" , #GST_SEEK_TYPE_SET -- absolute position is requested
      500*GST_SECOND, #cur
      "GST_SEEK_TYPE_NONE", #stop_type. GST_SEEK_TYPE_NONE.
      #510*GST_SECOND, #stop. 0 i guess?
      -1,
   );

   # /* And wait for this seek to complete */
   $player->get_state(-1);#, NULL, NULL, GST_CLOCK_TIME_NONE);
   #gboolean gst_element_seek (GstElement *element, gdouble rate, GstFormat format, GstSeekFlags flags, GstSeekType cur_type, gint64 cur, GstSeekType stop_type, gint64 stop);
   ;
}

sub dump_screenshot{
#   my $buf = GSignal->emit_by_name($player, 'convert-frame', $img_caps);
   my $buf = $player->signal_emit ('convert-frame', $img_caps);
   sleep(1);
   die $buf;
}

my $loop = Glib::MainLoop -> new(undef, FALSE);
setup_player();

$player -> set(uri => Glib::filename_to_uri $filename, "localhost");
#$player -> get_bus() -> add_watch(\&my_bus_callback, $loop);

print "Playing: $filename\n";

$player -> set_state("playing") or die "Could not start playing";
   sleep(1);
seek_to_random_frame();

dump_screenshot();

if (1){
   sleep(1);
   $loop -> run();
   $player -> set_state("null");
}

