package PDL::GStreamer;
use Moose 'has';
use MooseX::Types::Path::Class;
use PDL;
use GStreamer qw/ -init GST_SECOND /;
use Glib qw/TRUE FALSE/;
#use GStreamer::App;
use POSIX ();
use Carp 'confess';

my $loop = Glib::MainLoop->new();

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
   isa => 'Glib::Object::_Unregistered::GstAppSink',
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
   my $audio_sink = GStreamer::ElementFactory->make ("appsink", "audio-appsink");

   $pipeline->add($decoder, $audio_sink);

   $decoder->set(uri => Glib::filename_to_uri $self->filename, "localhost");
   $audio_sink->set("sync", FALSE);

#   $decoder->link($audio_sink);
   $self->_audio_decoder($decoder);
   $self->_audiosink($audio_sink);

   $pipeline->set_state('paused');
   return $pipeline;
   my @state = $pipeline->get_state(-1);
   warn @state;
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

#this is not used..
sub audio_caps{
   my $self = shift;
   my $audio_caps = GStreamer::Caps::Simple->new ("audio/x-raw-int",
      'signed', 'Glib::Boolean',FALSE,
      'width','Glib::Int',8,
      'depth','Glib::Int',8,
   );
   return $audio_caps;
}

# it turns out polling is evil. Are you evil, gstreamer?
sub _poll_for_async_done{
   my ($self,$bus) = @_;
   while(1){
      my $msg = $bus->poll('any',-1);#([qw/error async-done/], -1);
      last if ($msg->type & 'async-done');
      die $msg if $msg->type & 'error';
   }
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
   if ($self->do_audio){
      my $p = $self->_audio_pipeline;
      #$self->_audio_decoder->link($self->_audiosink);
      #my $ok = $p->seek(@seek_params);
      my $ok = $p->seek(@seek_params);
      #my $ok = $self->_audio_decoder->seek(@seek_params);
      sleep(1);
      warn $p->get_state(-1);
      #warn $self->_audio_decoder->get_state(-1);
      warn 'TIME: '. $self->query_time();
      #die 'seek not handled correctly?' unless $ok;
   }
   if ($self->do_video){
      die;
      my $ok = $self->player->seek(@seek_params);
      die 'seek not handled correctly?' unless $ok;
   }
}

sub query_time{
   my $self = shift;
   my $q = GStreamer::Query::Position->new('time'); #bleh
   my @q = $self->_audio_pipeline->query($q);
   return $q->position / GST_SECOND; 
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
   $audiosink->set(emit_signals => TRUE);
   $audiosink->set("sync", FALSE);
   my @datas;
   my $datatarget;
   my $datasize=0;
   $self->_audio_decoder->signal_connect('pad-added', sub{
         warn 'buf pad!';
         my ($adbin, $pad) = @_;
         #$pad->link($audiosink->get_pad('sink'));
         #die $self->_audio_decoder;
         $self->_audio_decoder->link($audiosink);
      }
   );
   #this probably isn't the same as EOS.
   #$self->_audio_decoder->signal_connect('no-more-pads', sub{
   #      my ($adbin) = @_;
   #      warn 'end of stream';
   #      $loop->quit;
   #   }
   #);
   $audiosink->signal_connect("new-buffer", sub{
         #my $audiosink = shift;
         warn 'pulling buf.';
         #warn $audiosink->get('emit-signals');
         warn 'EOS?' if $audiosink->get('eos');
         my $buf = $audiosink->signal_connect('pull_buffer');
         warn $buf;
         warn $self->query_time();
         #warn 'NEXT';
         #warn $buf->size;
         unless ($format){
            $caps = $buf->get_caps();
            $format = _read_audio_caps($caps);
            $datatarget = $format->{channels} * $seconds *
                          ($format->{width}/8) * $format->{rate};
         }
         push @datas, $buf->data;
         $datasize += $buf->size;
         $loop->quit if $datasize >= $datatarget;
         $loop->quit if $audiosink->get('eos');
         return 1;
      }
   );
   $self->_audio_decoder->get_bus()->signal_connect( 'message', sub{
         my ($bus,$msg,$udata) = @_;
         if ($msg->type & 'error' or $msg->type & 'warning'){
            warn $msg->error;
            warn $msg->debug;
         }
         elsif($msg->type & 'stream-status'){
            warn Dumper $msg->get_structure->{fields}[0][2] . 'streamstatus';
         }
         else {
            warn $msg->type;
         }
         return 1;
      }
   );
   $self->seek(30);
   #warn $self->_audio_pipeline->get_state(-1);
   $self->_audio_pipeline->set_state('playing');
   $self->_audiosink->set("sync", FALSE);
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
