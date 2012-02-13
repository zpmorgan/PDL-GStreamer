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
      close $self->raw_video_fd;
      close $self->raw_audio_fd;
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

has [qw/raw_audio_fifo raw_video_fifo/] => (
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

has [qw/raw_audio_fd raw_video_fd/] => (#set with gst-launch!
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
   close($self->raw_video_fd) if $self->do_video;
   close($self->raw_audio_fd) if $self->do_audio;
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

sub num_channels{
   my $self = shift;
   return 2 if $self->avconv_info() =~ /stereo/;
   return 1;
}
sub sample_rate{
   my $self = shift;
   $self->avconv_info() =~ / (\d+) Hz/
      or die 'no audio rate? ' . $self->avconv_info;
   return $1;
}
sub play{
   my $self = shift;
   die 'we require audio and/or video.' 
      unless $self->do_audio or $self->do_video;
   $self->raw_video_fifo; #initialize fifo

   my $start_time = int($self->start_time * 10**9);
   my $duration = '100' . $nine_zeros;

   my $audio_pipeline = '';
   my $video_pipeline = '';

   #this works:
   # gst-launch gnlfilesource caps="audio/x-raw-int" \
   #     location=file:///home/zach/projects/PDL-GStreamer/foo.avi \
   #      duration=10000000000 ! audioconvert ! audioresample ! autoaudiosink
   if($self->do_audio){
      $audio_pipeline = 
         "gnlfilesource location=file://".$self->filename->absolute ." ".
            "media-start=$start_time media-duration=$duration ".
            "caps='audio/x-raw-int' ! ".
         'audioconvert ! audioresample ! '.
         'filesink location=' . $self->raw_audio_fifo . ' '
      ;
   }
   if ($self->do_video){
      #$reformat: caps such as this:   
      #"video/x-raw-yuv,width=32,height=32,framerate=50/1 ! ".
      my $reformat = 'video/x-raw-yuv';
      $reformat .= ',width='.$self->scale_w if $self->scale_w;
      $reformat .= ',height='.$self->scale_h if $self->scale_h;
      $reformat .= ',framerate=50/1' if 1;

      my $scaled_autosink = 
         $self->do_play()
            ?  "t. ! queue ! videoscale method=0 ! ".
               "video/x-raw-yuv,width=600,height=600 ! autovideosink "
            : '';

      $video_pipeline = 
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
               "filesink location=" . $self->raw_video_fifo . " "
               #"fdsink ".
      ;
   }
   my $gst_launch_cmd = "gst-launch $audio_pipeline $video_pipeline |";
   #die $gst_launch_cmd;
   my $gst_launch_output; #info about pipelines,etc.
   my $gst_pid =  open ($gst_launch_output, $gst_launch_cmd) or die $!;
   $self->info_fd($gst_launch_output);
   $self->gst_pid($gst_pid);

   if ($video_pipeline){ #open video fd 
      my $fd;
      open($fd,'<',$self->raw_video_fifo) or die $!;
      $self->raw_video_fd($fd);
   }
   if ($audio_pipeline){ #open audio fd
      my $fd;
      open($fd,'<',$self->raw_audio_fifo) or die $!;
      $self->raw_audio_fd($fd);
   }
   #my $header;
   #read($gst_launch_output, $header, 128);
   #die $header;
   $self->playing(1);
}

sub frame_size_in_bytes{
   my $self = shift;
   return 3 * $self->width * $self->height;
}

sub get_frame{
   my $self = shift;
   #warn;
   $self->play() unless $self->playing();
   my $data;
   read($self->raw_video_fd,$data,$self->frame_size_in_bytes);
   my $img = pdl(unpack("C*",$data));
   #$img = $img->float / 256;
   #imag2d $img->reshape(3,32,32);
   return $img;
}

sub get_audio{
   my ($self,$seconds) = @_;
   $self->play() unless $self->playing();

   my $depth = 2;
   my $channels = $self->num_channels;
   my $rate = $self->sample_rate;
   my $samples = int($rate * $seconds);

   my $data;
   read($self->raw_audio_fd, $data, $samples*$channels*$depth);

   my @data = unpack ('s*' , $data); #bleh.
   my $piddle = pdl(@data);
   $piddle->reshape($channels, $piddle->dim(0)/$channels);
   return ($piddle);
}

'excelloriffying';
