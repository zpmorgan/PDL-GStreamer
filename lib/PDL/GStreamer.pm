package PDL::GStreamer;
use Moose 'has';
use MooseX::Types::Path::Class;
use PDL;
use POSIX ();
use Carp 'confess';
use PDL::Graphics2D 'imag2d';

my $nine_zeros = '000000000';

my ($loop); #cruft below.

has gst_pid => (
   is => 'rw',
   isa => 'Int',
   clearer => 'clear_gst_pid',
);

has playing => (
   is => 'rw',
   isa => 'Bool',
   default => 0,
);

has start_time => (#seconds
   isa => 'Num',
   is => 'rw',
   default => 0,
   trigger => sub{
      my $self=shift;
      $self->playing(0);
   },
);
sub seek{
   my($self,$time)=@_;
   if($self->playing){
      close $self->input_fd;
      close $self->info_fd;
   }
   if ($self->gst_pid){
      kill 15, $self->gst_pid;
      $self->clear_gst_pid;
   }
   $self->start_time($time);
}

has filename => (
   is => 'ro',
   isa => 'Path::Class::File',
   coerce => 1,
   required => 1,
);

has _abs_filename => (
   is => 'ro',
   isa => 'foo',
);

has [ qw/do_play do_audio do_video/ ] => (
   is => 'ro',
   isa => 'Bool',
   default => 1,
);

has input_fifo => (
   is => 'ro',
   isa => 'Path::Class::File',
   coerce => 1,
   default => sub{
      my $path = '/tmp/'.rand();
      system('mkfifo',$path);
      return $path;
   },
   lazy => 1,
);

has input_fd => (#set before gst-launch!
   is => 'rw',
   isa => 'FileHandle',
);
has info_fd => (
   is => 'rw',
   isa => 'FileHandle',
);

use IPC::Open3;

has avconv_info => (
   is => 'ro',
   isa => 'Str',
   default => sub{
      my $self = shift;
      my $cmd = 'avconv -i '. $self->filename;
      my $foo;
      my ($w,$r,$e);
      open3 ($w,$r,$e, "$cmd");
      return join ('',<$r>);
      #my $info = `$cmd`;
      #die $info;
   },
   lazy => 1,
);

has [qw/scale_w scale_h/] => (
   isa => 'Int',
   is => 'ro',
   required => 0,
);

sub DEMOLISH{
   my $self = shift;
   return unless $self->playing;
   kill 15, $self->gst_pid;
   close($self->info_fd);
   close($self->input_fd);
}


sub width{
   my $self = shift;
   return $self->scale_w if $self->scale_w;
   $self->avconv_info() =~ / (\d+)x(\d+) /
      or die 'no width? ' . $self->avconv_info;
   return $1;
}
sub height{
   my $self = shift;
   return $self->scale_h if $self->scale_h;
   $self->avconv_info() =~ /\b(\d+)x(\d+)\b/
      or die 'no height? ' . $self->avconv_info;
   return $2;
}

sub duration{
   my $self = shift;
   $self->avconv_info() =~ /Duration: (\d\d):(\d\d):(\d\d\.?\d?\d?),/
      or die 'no duration? ' . $self->avconv_info;
   return $1*3600 + $2*60 + $3;
}

sub play{
   my $self = shift;
   $self->input_fifo; #initialize fifo

   my $start_time = int($self->start_time * 10**9);
   my $duration = '100' . $nine_zeros;

   my $scaled_autosink = 
      $self->do_play()
         ?  "t. ! queue ! videoscale method=0 ! ".
            "video/x-raw-yuv,width=600,height=600 ! autovideosink "
         : '';

   #$reformat: caps such as this:   
   #"video/x-raw-yuv,width=32,height=32,framerate=50/1 ! ".
   my $reformat = 'video/x-raw-yuv';
   $reformat .= ',width='.$self->scale_w if $self->scale_w;
   $reformat .= ',height='.$self->scale_h if $self->scale_h;
   $reformat .= ',framerate=50/1' if 1;

   #this works:
   # gst-launch gnlfilesource caps="audio/x-raw-int" \
   #     location=file:///home/zach/projects/PDL-GStreamer/foo.avi \
   #      duration=10000000000 ! audioconvert ! audioresample ! autoaudiosink
   my $audio_pipeline = ' ' ;
   #   "gnlfilesource location=file://".$self->filename->absolute ." ".
   #      "media-start=$start_time media-duration=$duration ! ".
   #   'audioconvert ! audioresample ! '.
   #   'filesink location=' . $self->raw_audio_fifo . ' ';

   my $video_pipeline = 
      #"gst-launch v4l2src ! ".
      #"gst-launch filesrc location=/tmp/neato/tron.avi ! ".
      "gnlfilesource location=file://".$self->filename->absolute ." ".
         "media-start=$start_time media-duration=$duration ! ".
      #"decodebin2 ! ".#video/x-raw-rgb ! ".
      "videoscale method=3 ! ".
      "videorate ! ".
      $reformat . ' ! '.
      "tee name=t  ".
         $scaled_autosink .
         "t. ! queue ! ffmpegcolorspace ! ".
            "video/x-raw-rgb ! ".
            "filesink location=" . $self->input_fifo . " "
            #"fdsink ".
      ;
   my $gst_launch_cmd = "gst-launch $audio_pipeline $video_pipeline |";
   #die $gst_launch_cmd;
   my $gst_launch_output; #info about pipelines,etc.
   my $gst_pid =  open ($gst_launch_output, $gst_launch_cmd) or die $!;
   $self->info_fd($gst_launch_output);
   $self->gst_pid($gst_pid);

   { #open input_fd
      my $fd;
      open($fd,'<',$self->input_fifo) or die $!;
      $self->input_fd($fd);
   }
   #open ($gst_pipe,'<',$self->input_fifo) or die $!;
   #my $header;
   #read($gst_launch_output, $header, 128);
   #die $header;
   $self->playing(1);
}
#my $header;
#read($gst_launch_output, $header, 228);
#die $header;

sub frame_size_in_bytes{
   my $self = shift;
   return 3 * $self->width * $self->height;
}

sub get_frame{
   my $self = shift;
   #warn;
   $self->play() unless $self->playing();
   my $data;
   read($self->input_fd,$data,$self->frame_size_in_bytes);
   my $img = pdl(unpack("C*",$data));
   #$img = $img->float / 256;
   #imag2d $img->reshape(3,32,32);
   return $img;
}

sub capture_frame{
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
   $self->_audio_pipeline; #build ifn't already
   my $caps;
   my $format;
   my $audiosink = $self->_audiosink;
   #$audiosink->set(emit_signals => TRUE);
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
   $audiosink->signal_connect("handoff", sub{
         my ($sink,$buf,$pad) = @_;
         #my $audiosink = shift;
         warn 'pulling buf.';
         #warn $audiosink->get('emit-signals');
         #warn 'EOS?' if $audiosink->get('eos');
#         my $buf = $audiosink->signal_emit('last-buffer');
         #warn $buf;
         my $data = $buf->data;
         my $size = $buf->size;
         #warn 'NEXT';
         #warn $buf->size;
         unless ($format){
            $caps = $buf->get_caps();
            $format = _read_audio_caps($caps);
            $datatarget = $format->{channels} * $seconds *
                          ($format->{width}/8) * $format->{rate};
         }
         warn $self->query_time();
         push @datas, $data;
         $datasize += $size;
         $loop->quit if $datasize >= $datatarget;
         #$loop->quit if $audiosink->get('eos');
         #warn $buf;
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
   #$self->seek(30);
   #warn $self->_audio_pipeline->get_state(-1);
   $self->_audio_pipeline->set_state('playing');
   $loop->run;
   $self->_audio_pipeline->set_state('null');

   my $data = join '',@datas;

   my @data = unpack ($format->{packtemplate}.'*' , $data); #bleh.
   my $piddle = pdl(@data);
   $piddle->reshape($format->{channels}, $piddle->dim(0)/$format->{channels});
   return ($piddle,$format);
}

'excelloriffying';
