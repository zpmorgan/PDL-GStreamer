package PDL::GStreamer;
use Moose 'has';
use MooseX::Types::Path::Class;
use PDL;
use GStreamer qw/ -init GST_SECOND /;
use Glib qw/TRUE FALSE/;
use GStreamer::App;
use POSIX ();

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

my $plug = GStreamer::Plugin::load_by_name('app');
#die $plug->get_filename; #/usr/lib/gstreamer-0.10/libgstapp.so
#my $registry = GStreamer::Registry -> get_default();
#my @features = $registry->get_feature_list_by_plugin("app");
#die join ',',map {$_->get_name}@features;
#die %{$features[2]};

sub _mk_player{
   my $self = shift;
   my $player = GStreamer::ElementFactory -> make(playbin2 => "player");
   # http://git.gnome.org/browse/totem/tree/src/totem-video-thumbnailer.c
   # http://git.gnome.org/browse/totem/tree/src/gst/totem-gst-helpers.c
   my $audio_sink = GStreamer::ElementFactory->make ("appsink", "audio-app-sink");
   my $video_sink = GStreamer::ElementFactory->make ("fakesink", "video-fake-sink");
   $video_sink->set("sync", TRUE);
   $self->_audiosink($audio_sink);
   $self->_videosink($video_sink);
   #$audio_sink->set_caps($self->audio_caps);
   #use Data::Dumper;
   #die Dumper $self->_audiosink->list_properties();

   $player->set(
      "audio-sink" => $audio_sink,
      "video-sink" => $video_sink,
      "flags" => [qw/ video audio /],# GST_PLAY_FLAG_VIDEO GST_PLAY_FLAG_AUDIO /],
   );
   $player -> set(uri => Glib::filename_to_uri $self->filename, "localhost");
   #$player->set_state('playing');
   $player->set_state('paused');
   my @state = $player->get_state(-1);
   die join(',',@state) unless $state[0] eq 'success';
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
   #
   #NOTE: Check out caps = Gst::Caps->from_string
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
sub audio_caps{
   my $self = shift;
   my $audio_caps = GStreamer::Caps::Simple->new ("audio/x-raw-int",
      'signed', 'Glib::Boolean',FALSE,
      'width','Glib::Int',8,
      'depth','Glib::Int',8,
   );
   return $audio_caps;
}

sub seek{
   my ($self,$time) = @_;
   $self->check_video;
   my $ok = $self->player->seek(
      1, #rate
      "time", #3, #format. GST_FORMAT_TIME(), #format
      [qw/accurate flush/],#"GST_SEEK_FLAG_ACCURATE", #flags
      "set" , #GST_SEEK_TYPE_SET -- absolute position is requested
      $time * GST_SECOND, #cur
      "none", #stop_type. GST_SEEK_TYPE_NONE.
      -1, # stop.
   );

   my $bus = $self->player->get_bus();
   while(1){ #wait for seek to complete.
      my $msg = $bus->poll('any',-1);#([qw/error async-done/], -1);
      last if ($msg->type & 'async-done');
      die $msg if $msg->type & 'error';
#      warn $msg;
   }
   my @state = $self->player->get_state(-1);
   die 'seek not handled correctly?' unless $ok;
}

sub capture_image{
   my $self = shift;

   my $buf = $self->player->signal_emit ('convert-frame', $self->image_caps);
   my $caps = $buf->get_caps->get_structure(0);
   # convert GstStructure to {name => [name,type,value], ...}
   my %caps = map {$_->[0]  => $_} @{$caps->{fields}};
   my $height = $caps{height}[2];
   my $width = $caps{width}[2];
   my $depth = $caps{depth}[2]; #24, as ordered.
   my $bpp = $caps{bpp}[2]; #also 24?
   #die $buf->duration; #maybe 1billion/29.97
   #die join "\n",%caps;
   #width,height,{color}_mask,depth,pixel-aspect-ratio,endianness,bpp
   my $piddle = pdl unpack('C*',$buf->data);
   $piddle->inplace->reshape(3,$width,$height);
   return $piddle; #not scaled. range:0-255.

}

sub capture_audio{
   my ($self,$seconds) = @_;
   my $initbuf = $self->_audiosink->pull_preroll;
   my $caps = $initbuf->get_caps->to_string;
   #my $caps = $buf->get_caps->get_structure(0);
   #warn $caps;
   my ($endian) = $caps =~ /endianness=\(int\)(\d)/;
   my $littleendian = $endian==4;
   my ($rate) = $caps =~ /rate=\(int\)(\d+)\b/;
   my ($signed) = $caps =~ /signed=\(boolean\)(\w+)\b/;
   my $signedness = $signed eq 'true';
   #ignoring depth. I don't suppose it's relevant.
   my ($width) = $caps =~ /width=\(int\)(\d+)\b/;
   my ($channels) = $caps =~ /channels=\(int\)(\d)/;

   $self->player->set_state('playing');
   my $num_buffers = POSIX::ceil(
      $channels * $seconds *($width/8) * $rate / $initbuf->size);

   my @datas;
   for (1..$num_buffers){
      my $buf = $self->_audiosink->pull_buffer();
      push @datas,$buf->data;
   }

   my $ptemplate; #TEMPLATE for unpack. bleh.
   $ptemplate = 'n' if (($width==16) and !$littleendian);
   $ptemplate = 's' if (($width==16) and $littleendian);
   die "$caps unpackable?" unless $ptemplate;

   my $data = join '',@datas;
   my $format = {
      littleendian => $littleendian,
      rate => $rate,
      width => $width,
      signed => $signedness,
      channels => $channels,
      packtemplate => $ptemplate,
   };

   my @data = unpack ($ptemplate.'*' , $data); #bleh.
   my $piddle = pdl(@data);
   $piddle->reshape($channels, $piddle->dim(0)/$channels);
   return ($piddle,$format);
}


sub check_audio{
   my $self = shift;
   #my $naudiochannels = $self->player->get ('n-audio');
   my $tags = $self->player->signal_emit ('get-audio-tags',0);
   return ref ($tags) eq 'HASH';
}

sub check_video{
   my $self = shift;
   #my $nvideochannels = $self->player->get ('n-video');
   my $tags = $self->player->signal_emit ('get-video-tags',0);
   return ref ($tags) eq 'HASH';
}

'excelloriffying';
