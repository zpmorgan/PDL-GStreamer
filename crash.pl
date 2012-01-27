use GStreamer qw/ -init GST_SECOND /;
use Glib qw/TRUE FALSE/;
use POSIX ();
use Carp 'confess';
use File::Spec;

my $loop = Glib::MainLoop->new();
my $filename = File::Spec->rel2abs('foo.mp3');

my $pipeline = GStreamer::Pipeline->new('audio-pipe');
my $decoder = GStreamer::ElementFactory->make (uridecodebin=>'audio-decoder');
my $audio_sink = GStreamer::ElementFactory->make ("appsink", "audio-appsink");

$pipeline->add($decoder, $audio_sink);
$decoder->link($audio_sink);
$decoder->set(uri => Glib::filename_to_uri ($filename, "localhost"));
$audio_sink->set("sync", FALSE);
$audio_sink->set(emit_signals => TRUE);

$pipeline->set_state('ready');
my @state = $pipeline->get_state(-1);
warn @state;

# seeking does not work...
audio_seek(25);
capture_audio(1);
audio_seek(25);
capture_audio(1);

sub audio_seek{
   my ($time) = @_;
   my @seek_params = (
      1, #rate
      "time", #3, #format. GST_FORMAT_TIME(), #format
      [qw/accurate flush/],#"GST_SEEK_FLAG_ACCURATE", #flags
      "set" , #GST_SEEK_TYPE_SET -- absolute position is requested
      $time * GST_SECOND, #cur
      "none", #stop_type. GST_SEEK_TYPE_NONE.
      -1, # stop.
   );
   my $ok = $pipeline->seek(@seek_params);
   #sleep(1);
   warn $pipeline->get_state(-1);
   warn 'TIME: '. query_time();
}

sub query_time{
   my $q = GStreamer::Query::Position->new('time'); #bleh
   my @q = $pipeline->query($q);
   return $q->position / GST_SECOND; 
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
   my ($seconds) = @_;
   my $caps;
   my $format;
   my @datas;
   my $datatarget;
   my $datasize=0;
   $decoder->signal_connect('pad-added', sub{
         my ($adbin, $pad) = @_;
         warn 'decoder pad!';
         $decoder->link($audio_sink);
      }
   );
   $audio_sink->signal_connect("new-buffer", sub{
         warn 'pulling buf.';
         warn 'EOS?' if $audio_sink->get('eos');
         #buf isn't permenant for some reason. 
         #Some gstreamer thread will come along and wipe it out.
         #or something.
         my $buf = $audio_sink->signal_emit('pull_buffer');
         my $data = $buf->data;
         my $size = $buf->size;
         warn query_time();
         unless ($format){
            $caps = $buf->get_caps();
            $format = _read_audio_caps($caps);
            $datatarget = $format->{channels} * $seconds *
                          ($format->{width}/8) * $format->{rate};
         }
         push @datas, $data;
         $datasize += $size;
         $loop->quit if $datasize >= $datatarget;
         $loop->quit if $audio_sink->get('eos');
#the following line causes all sorts of fascinating errors.
         warn $buf;
         return 1;
      }
   );
   #this signal doesn't seem to work.
   $decoder->get_bus()->signal_connect( 'message', sub{
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
   $pipeline->set_state('playing');
   $loop->run;
   warn %$format;
   $pipeline->set_state('null');

   my $data = join '',@datas;

   #my @data = unpack ($format->{packtemplate}.'*' , $data); #bleh.

   my $pa;
   open ($pa,'|pacat --format=s16le --channels=1');
   print $pa $data;
   close($pa);
   return @data;
   #my $piddle = pdl(@data);
   #$piddle->reshape($format->{channels}, $piddle->dim(0)/$format->{channels});
   #return ($piddle,$format);
}

__END__
Here are some errors it presents when $buf is accessed some time after being pulled:

Can't call method "set_state" on an undefined value at crash.pl line 138.
Aborted (core dumped)


Segmentation fault (core dumped)



*** glibc detected *** perl: double free or corruption (fasttop): 0x0a10d9c0 ***
======= Backtrace: =========
/lib/i386-linux-gnu/libc.so.6(+0x72892)[0xb7669892]
/lib/i386-linux-gnu/libc.so.6(+0x73532)[0xb766a532]
/lib/i386-linux-gnu/libc.so.6(cfree+0x6d)[0xb766d61d]
perl(Perl_sv_clear+0x315)[0x80e2415]
perl(Perl_sv_free2+0x36)[0x80e2a96]
perl(Perl_free_tmps+0x5d)[0x80fc67d]
perl(Perl_pp_nextstate+0x65)[0x80d3575]
perl(Perl_runops_standard+0xb)[0x80d2f1b]
perl(perl_run+0x325)[0x807b035]
perl(main+0x105)[0x80601a5]
/lib/i386-linux-gnu/libc.so.6(__libc_start_main+0xf3)[0xb7610113]
perl[0x80601d5]
======= Memory map: ========
08048000-08187000 r-xp 00000000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
08187000-08188000 r--p 0013e000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
08188000-0818a000 rw-p 0013f000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
0818a000-0818b000 rw-p 00000000 00:00 0 
09d9b000-0a1a3000 rw-p 00000000 00:00 0          [heap]
b59e8000-b5a04000 r-xp 00000000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5a04000-b5a05000 r--p 0001b000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5a05000-b5a06000 rw-p 0001c000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5a06000-b5a5e000 rw-p 00000000 00:00 0 
b5a5e000-b5a5f000 ---p 00000000 00:00 0 
b5a5f000-b625f000 rw-p 00000000 00:00 0 
b625f000-b62c1000 r-xp 00000000 08:06 19805348   /usr/lib/i386-linux-gnu/liboil-0.3.so.0.3.0
b62c1000-b62c2000 ---p 00062000 08:06 19805348   /usr/lib/i386-linux-gnu/liboil-0.3.so.0.3.0
b62c2000-b62c3000 r--p 00062000 08:06 19805348   /usr/lib/i386-linux-gnu/liboil-0.3.so.0.3.0
b62c3000-b62d9000 rw-p 00063000 08:06 19805348   /usr/lib/i386-linux-gnu/liboil-0.3.so.0.3.0
b62d9000-b62dc000 rw-p 00000000 00:00 0 
b6300000-b6339000 rw-p 00000000 00:00 0 
b6339000-b6400000 ---p 00000000 00:00 0 
b6405000-b6435000 r-xp 00000000 08:06 19794166   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstflump3dec.so
b6435000-b6436000 r--p 0002f000 08:06 19794166   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstflump3dec.so
b6436000-b6437000 rw-p 00030000 08:06 19794166   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstflump3dec.so
b6437000-b6438000 ---p 00000000 00:00 0 
b6438000-b6c38000 rw-p 00000000 00:00 0 
b6c38000-b6c6c000 r-xp 00000000 08:06 19798389   /usr/lib/i386-linux-gnu/libgsttag-0.10.so.0.25.0
b6c6c000-b6c6d000 r--p 00033000 08:06 19798389   /usr/lib/i386-linux-gnu/libgsttag-0.10.so.0.25.0
b6c6d000-b6c6e000 rw-p 00034000 08:06 19798389   /usr/lib/i386-linux-gnu/libgsttag-0.10.so.0.25.0
b6c6e000-b6c81000 r-xp 00000000 08:06 2893842    /lib/i386-linux-gnu/libresolv-2.13.so
b6c81000-b6c82000 r--p 00012000 08:06 2893842    /lib/i386-linux-gnu/libresolv-2.13.so
b6c82000-b6c83000 rw-p 00013000 08:06 2893842    /lib/i386-linux-gnu/libresolv-2.13.so
b6c83000-b6c85000 rw-p 00000000 00:00 0 
b6c85000-b6ca2000 r-xp 00000000 08:06 2884022    /lib/i386-linux-gnu/libselinux.so.1
b6ca2000-b6ca3000 r--p 0001c000 08:06 2884022    /lib/i386-linux-gnu/libselinux.so.1
b6ca3000-b6ca4000 rw-p 0001d000 08:06 2884022    /lib/i386-linux-gnu/libselinux.so.1
b6ca4000-b6e02000 r-xp 00000000 08:06 19796187   /usr/lib/i386-linux-gnu/libgio-2.0.so.0.3112.0
b6e02000-b6e04000 r--p 0015e000 08:06 19796187   /usr/lib/i386-linux-gnu/libgio-2.0.so.0.3112.0
b6e04000-b6e05000 rw-p 00160000 08:06 19796187   /usr/lib/i386-linux-gnu/libgio-2.0.so.0.3112.0
b6e05000-b6e06000 rw-p 00000000 00:00 0 
b6e0d000-b6e12000 r-xp 00000000 08:06 19797798   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreindexers.so
b6e12000-b6e13000 r--p 00005000 08:06 19797798   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreindexers.so
b6e13000-b6e14000 rw-p 00006000 08:06 19797798   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreindexers.so
b6e14000-b6e28000 r-xp 00000000 08:06 19798799   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstaudioparsers.so
b6e28000-b6e29000 r--p 00013000 08:06 19798799   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstaudioparsers.so
b6e29000-b6e2a000 rw-p 00014000 08:06 19798799   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstaudioparsers.so
b6e2a000-b6e72000 r-xp 00000000 08:06 19797796   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreelements.so
b6e72000-b6e73000 r--p 00048000 08:06 19797796   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreelements.so
b6e73000-b6e74000 rw-p 00049000 08:06 19797796   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstcoreelements.so
b6e74000-b6ed2000 r-xp 00000000 08:06 19797811   /usr/lib/i386-linux-gnu/libgstbase-0.10.so.0.30.0
b6ed2000-b6ed3000 r--p 0005d000 08:06 19797811   /usr/lib/i386-linux-gnu/libgstbase-0.10.so.0.30.0
b6ed3000-b6ed4000 rw-p 0005e000 08:06 19797811   /usr/lib/i386-linux-gnu/libgstbase-0.10.so.0.30.0
b6ed4000-b6edf000 r-xp 00000000 08:06 19798367   /usr/lib/i386-linux-gnu/libgstapp-0.10.so.0.25.0
b6edf000-b6ee0000 r--p 0000a000 08:06 19798367   /usr/lib/i386-linux-gnu/libgstapp-0.10.so.0.25.0
b6ee0000-b6ee1000 rw-p 0000b000 08:06 19798367   /usr/lib/i386-linux-gnu/libgstapp-0.10.so.0.25.0
b6ee1000-b6f01000 r-xp 00000000 08:06 19798371   /usr/lib/i386-linux-gnu/libgstpbutils-0.10.so.0.25.0
b6f01000-b6f02000 r--p 0001f000 08:06 19798371   /usr/lib/i386-linux-gnu/libgstpbutils-0.10.so.0.25.0
b6f02000-b6f03000 rw-p 00020000 08:06 19798371   /usr/lib/i386-linux-gnu/libgstpbutils-0.10.so.0.25.0
b6f05000-b6f07000 r-xp 00000000 08:06 19807404   /usr/lib/i386-linux-gnu/gconv/ISO8859-1.so
b6f07000-b6f08000 r--p 00001000 08:06 19807404   /usr/lib/i386-linux-gnu/gconv/ISO8859-1.so
b6f08000-b6f09000 rw-p 00002000 08:06 19807404   /usr/lib/i386-linux-gnu/gconv/ISO8859-1.so
b6f09000-b6f10000 r--s 00000000 08:06 19803644   /usr/lib/i386-linux-gnu/gconv/gconv-modules.cache
b6f10000-b6f24000 r-xp 00000000 08:06 19798707   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgsttypefindfunctions.so
b6f24000-b6f25000 r--p 00013000 08:06 19798707   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgsttypefindfunctions.so
b6f25000-b6f27000 rw-p 00014000 08:06 19798707   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgsttypefindfunctions.so
b6f27000-b6f43000 r-xp 00000000 08:06 19798687   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstdecodebin2.so
b6f43000-b6f44000 r--p 0001b000 08:06 19798687   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstdecodebin2.so
b6f44000-b6f45000 rw-p 0001c000 08:06 19798687   /usr/lib/i386-linux-gnu/gstreamer-0.10/libgstdecodebin2.so
b6f45000-b6f50000 r-xp 00000000 08:06 2885628    /lib/i386-linux-gnu/libnss_files-2.13.so
b6f50000-b6f51000 r--p 0000a000 08:06 2885628    /lib/i386-linux-gnu/libnss_files-2.13.soAborted (core dumped)





Can't call method "set_state" on an undefined value at crash.pl line 138.
======= Backtrace: =========
[0x1]
[0x44]
/lib/i386-linux-gnu/libc.so.6(-0xb7580000)[0x0]
perl(Perl_hv_placeholders_set+0x23)[0x80cd643]
[0x8cda748]
[0x25]
======= Memory map: ========
08048000-08187000 r-xp 00000000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
08187000-08188000 r--p 0013e000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
08188000-0818a000 rw-p 0013f000 08:06 16650707   /home/zach/perl5/perlbrew/perls/perl-5.15.6/bin/perl5.15.6
0818a000-0818b000 rw-p 00000000 00:00 0 
08cc6000-090c1000 rw-p 00000000 00:00 0          [heap]
75900000-b5900000 rw-p 00000000 00:00 0 
b5900000-b5926000 rw-p 00000000 00:00 0 
b5926000-b5a00000 ---p 00000000 00:00 0 
b5ace000-b5aea000 r-xp 00000000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5aea000-b5aeb000 r--p 0001b000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5aeb000-b5aec000 rw-p 0001c000 08:06 2892155    /lib/i386-linux-gnu/libgcc_s.so.1
b5aec000-b5aed000 ---p 00000000 00:00 0 
b5aed000-b62ed000 rw-p 00000000 00:00 0 
b62ed000-b634f000 r-xp 00000000 08:06 19805348   /usr/lib/i386-linux-gnu/liboil-0.3.so.0.3.0
b634f000-b6350000 ---p 00062000 08:06 19805348   /usr/liAborted (core dumped)



