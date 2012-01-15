package PDL::GStreamer;
use Moose 'has';
use MooseX::Types::Path::Class;
use PDL;
use GStreamer qw/ -init GST_SECOND /;
use Glib qw/TRUE FALSE/;

#my $appsinkplugin = GStreamer::Plugin::load_by_name('app');
#die unless $appsinkplugin->get_description;

# http://gstreamer.freedesktop.org/data/doc/gstreamer/head/manual/html/section-data-spoof.html

has filename => (
   is => 'ro',
   isa => 'Path::Class::File',
   coerce => 1,
   required => 1,
);

has player => (
   builder => '_mk_player',
   lazy => 1,
   is => 'ro',
   isa => 'GStreamer::Pipeline',
);

has _audiosink => (
   is => 'rw',
   #seems like this 'isa' could break.
   #isa => 'Glib::Object::_Unregistered::GstFakeSink',
   required => 0,
);
has _videosink => (
   is => 'rw',
   #seems like this 'isa' could break.
   #isa => 'Glib::Object::_Unregistered::GstFakeSink',
   required => 0,
);

sub _mk_player{
   my $self = shift;
   my $player = GStreamer::ElementFactory -> make(playbin2 => "player");
   # http://git.gnome.org/browse/totem/tree/src/totem-video-thumbnailer.c
   # http://git.gnome.org/browse/totem/tree/src/gst/totem-gst-helpers.c
   my $audio_sink = GStreamer::ElementFactory->make ("fakesink", "audio-fake-sink");
   #my $video_sink = GStreamer::ElementFactory->make ("fakesink", "video-fake-sink");
   my $video_sink = GStreamer::ElementFactory->make ("fakesink", "video-app-sink");
   $video_sink->set("sync", TRUE);
   $self->_audiosink($audio_sink);
   $self->_videosink($video_sink);

   $player->set(
      "audio-sink" => $audio_sink,
      "video-sink" => $video_sink,
      "flags" => [qw/ video audio /],# GST_PLAY_FLAG_VIDEO GST_PLAY_FLAG_AUDIO /],
   );
   $player -> set(uri => Glib::filename_to_uri $self->filename, "localhost");
   return $player;
}

sub image_caps{
   my $self = shift;
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
   return $img_caps;
}


sub seek{
   my ($self,$time) = @_;
   my $ok = $self->player->seek(
      1, #rate
      "time", #3, #format. GST_FORMAT_TIME(), #format
      [qw/accurate/],#"GST_SEEK_FLAG_ACCURATE", #flags
      "set" , #GST_SEEK_TYPE_SET -- absolute position is requested
      $time * GST_SECOND, #cur
      "none", #stop_type. GST_SEEK_TYPE_NONE.
      -1, # stop.
   );
   $self->player->get_state(-1);
   die 'seek not handled correctly?' unless $ok;
}

sub capture_image{
   my $self = shift;
#   my $buf = $self->_videosink->pull_preroll();
   #$self->player->set_state('playing');
   my @foo = $self->player->get_state(-1);
   #die @foo;
   my $buf = $self->player->signal_emit ('convert-frame', $self->image_caps);
   die $buf;
}



'excelloriffying';
