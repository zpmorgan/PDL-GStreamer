package PDL::GStreamer;
use Moose 'has';
use MooseX::Types::Path::Class;
use PDL;
use GStreamer qw/ -init GST_SECOND /;
use Glib qw/TRUE FALSE/;
use GStreamer::App;
use POSIX ();
use Carp 'confess';

my $loop = Glib::MainLoop->new();

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

has _audio_pipeline => (
   is => 'ro',
   lazy => 1,
   isa => 'GStreamer::Pipeline',
   builder => '_mk_audio_pipeline',
);
has _audio_decoder => (
   is => 'rw',
   isa => 'GStreamer::Element',
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
has [ qw/do_audio do_video/ ] => (
   is => 'ro',
   isa => 'Bool',
   default => 1,
);

has audio_datas => (
   is => 'rw',
   isa => 'ArrayRef',
   default => sub {[]},
);

#my $plug = GStreamer::Plugin::load_by_name('app');
# GstPipeline:audio-pipe
# GstURIDecodeBin:audio-decoder
# GstDecodeBin2:decodebin20
# GstMpegAudioParse:mpegaudioparse0:
sub _mk_audio_pipeline{
   my $self = shift;
   my $pipeline = GStreamer::Pipeline->new('audio-pipe');
   my $decoder = GStreamer::ElementFactory->make (uridecodebin=>'audio-decoder');
   #my $filter = GStreamer::ElementFactory->make (identity =>'noop');
   #my $conv = GStreamer::ElementFactory->make('audioconvert','aconv');
   my $audio_sink = GStreamer::ElementFactory->make ("appsink", "audio-appsink");

   #$pipeline->add($decoder,$conv, $audio_sink);
   $pipeline->add($decoder, $audio_sink);

   $pipeline->signal_connect ('pad-added', \&on_new_decoded_audio_pad, $audio_sink);
   # dynamic pads. bleh.
#unless ($decoder->link($filter,$audio_sink)){
#     $self->_reveal_errs($pipeline->get_bus);
#     die 'link failed';
#  }

   $decoder->set(uri => Glib::filename_to_uri $self->filename, "localhost");
   $pipeline->set_state('paused');
   $audio_sink->set("sync", FALSE);

   #$decoder->link($audio_sink);
   $self->_audio_decoder($decoder);
   $self->_audiosink($audio_sink);

   return $pipeline;
   my @state = $pipeline->get_state(-1);
   unless ($state[0] eq 'success'){
      $self->_reveal_errs($pipeline->get_bus);
   }
   return $pipeline;
}

sub on_new_decoded_audio_pad{
   my ($adbin,$pad, $appsink) = @_;
   $adbin->link($appsink);
}
sub no_more_audio_pads{
   my ($adbin) = @_;
   $loop->quit();
}

sub _mk_player{
   my $self = shift;
   confess 'fixme';
   my $player = GStreamer::ElementFactory -> make(playbin2 => "player");
   # http://git.gnome.org/browse/totem/tree/src/totem-video-thumbnailer.c
   # http://git.gnome.org/browse/totem/tree/src/gst/totem-gst-helpers.c
   my $audio_sink = GStreamer::ElementFactory->make ("appsink", "audio-fake-sink");
   my $video_sink = GStreamer::ElementFactory->make ("fakesink", "video-fake-sink");
   $video_sink->set("sync", TRUE);
   #$self->_audiosink($audio_sink);
   $self->_videosink($video_sink);

   $player->set(
#      "audio-sink" => $audio_sink,
      "video-sink" => $video_sink,
      "flags" => [qw/ video /],# GST_PLAY_FLAG_VIDEO GST_PLAY_FLAG_AUDIO /],
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

sub _poll_for_async_done{
   my ($self,$bus) = @_;
   while(1){
      my $msg = $bus->poll('any',-1);#([qw/error async-done/], -1);
      last if ($msg->type & 'async-done');
      die $msg if $msg->type & 'error';
   }
}
use Data::Dumper;
sub _reveal_errs{
   my ($self,$bus) = @_;
   my @errs;
   while(1){
      my $msg = $bus->poll('any',1);#([qw/error async-done/], -1);
      last unless $msg;
      if ($msg->type & 'error' or $msg->type & 'warning'){
         push @errs, $msg->error;
         push @errs, $msg->debug;
      }
      elsif($msg->type & 'stream-status'){
         warn Dumper $msg->get_structure->{fields}[0][2] . 'streamstatus';
      }
      else {
         warn $msg->type;
      }
   }
   return unless @errs;
   confess join "\n",@errs;
}

sub seek{
   my ($self,$time) = @_;
   #$self->check_video;

   my @seek_params = (
      1, #rate
      "time", #3, #format. GST_FORMAT_TIME(), #format
      [qw/accurate flush/],#"GST_SEEK_FLAG_ACCURATE", #flags
      "set" , #GST_SEEK_TYPE_SET -- absolute position is requested
      $time * GST_SECOND, #cur
      "none", #stop_type. GST_SEEK_TYPE_NONE.
      -1, # stop.
   );
   $self->_audio_pipeline;
   if ($self->do_audio){
      #my $ok = $self->_audio_pipeline->seek(@seek_params);
      my $ok = $self->_audio_pipeline->seek(@seek_params);
      #sleep 1;
      $self->_audio_pipeline->get_state(-1);
      #$self->_reveal_errs($self->_audio_pipeline->get_bus) unless $ok;
      #die 'seek not handled correctly?' unless $ok;
      #$self->_poll_for_async_done($self->_audio_pipeline->get_bus());
   }
   if ($self->do_video){
      my $ok = $self->player->seek(@seek_params);
      die 'seek not handled correctly?' unless $ok;
      $self->_poll_for_async_done($self->player->get_bus());
   }
   return;

   my $vbus = $self->player->get_bus();
   my $abus = $self->_audio_pipeline->get_bus();
   #die join '|',($abus,$bus);
   for my $bus ($abus,$vbus){
      while(1){ #wait for seek to complete.
         my $msg = $bus->poll('any',-1);#([qw/error async-done/], -1);
         last if ($msg->type & 'async-done');
         die $msg if $msg->type & 'error';
      }
   }
#   my @state = $self->player->get_state(-1);
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

sub _read_audio_caps{
   my $caps_obj = shift;
   my $caps = $caps_obj->to_string;

   my ($endian) = $caps =~ /endianness=\(int\)(\d)/;
   my $littleendian = $endian==4;
   my ($rate) = $caps =~ /rate=\(int\)(\d+)\b/;
   my ($signed) = $caps =~ /signed=\(boolean\)(\w+)\b/;
   my $signedness = $signed eq 'true';
   #ignoring depth. I don't suppose it's relevant.
   my ($width) = $caps =~ /width=\(int\)(\d+)\b/;
   my ($channels) = $caps =~ /channels=\(int\)(\d)/;
   
   my $ptemplate; #TEMPLATE for unpack. bleh.
   $ptemplate = 'n' if (($width==16) and !$littleendian);
   $ptemplate = 's' if (($width==16) and $littleendian);
   die "$caps unpackable?" unless $ptemplate;

   my $format = {
      littleendian => $littleendian,
      rate => $rate,
      width => $width,
      signed => $signedness,
      channels => $channels,
      packtemplate => $ptemplate,
   };
   return $format;
}

sub capture_audio{
   my ($self,$seconds) = @_;
   $self->_audio_pipeline; #build ifn't already
   my $caps;
   my $format;
   my $audiosink = $self->_audiosink;
   $audiosink->set_emit_signals(TRUE);
   my @datas;
   my $datatarget;
   my $datasize=0;
   $self->_audio_decoder->signal_connect('pad-added', sub{
         warn 'buf pad!';
         my ($adbin, $pad) = @_;
         $adbin->link($audiosink);
#   $self->_audiosink->set("sync", FALSE);
      }
   );
   $self->_audio_decoder->signal_connect('no-more-pads', sub{
         my ($adbin) = @_;
         #$loop->quit;
      }
   );
   $audiosink->signal_connect("new-buffer", sub{
         #my $audiosink = shift;
         my $buf = $audiosink->pull_buffer();
         unless ($format){
            $caps = $buf->get_caps();
            $format = _read_audio_caps($caps);
            $datatarget = $format->{channels} * $seconds *
                          ($format->{width}/8) * $format->{rate};
         }
         push @datas, $buf->data;
         $datasize += $buf->size;
         $loop->quit if $datasize >= $datatarget;
      }
   );
   $self->seek(30);
   $self->_audio_pipeline->set_state('playing');
   $loop->run;
   $self->_audio_pipeline->set_state('null');

   my $data = join '',@datas;

   my @data = unpack ($format->{packtemplate}.'*' , $data); #bleh.
   my $piddle = pdl(@data);
   $piddle->reshape($format->{channels}, $piddle->dim(0)/$format->{channels});
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
