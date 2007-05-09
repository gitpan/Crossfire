=head1 NAME

Crossfire::Protocol::Base - client protocol module

=head1 SYNOPSIS

   use base 'Crossfire::Protocol::Base'; # you have to subclass

=head1 DESCRIPTION

Base class to implement a crossfire client.

=over 4

=cut

package Crossfire::Protocol::Base;

our $VERSION = '0.98';

use strict;

use AnyEvent;
use IO::Socket::INET;

use Crossfire::Protocol::Constants;

use JSON::XS qw(from_json to_json);

=item new Crossfire::Protocol::Base host => ..., port => ...

=cut

sub new {
   my $class = shift;
   my $self = bless {
      host            => "crossfire.schmorp.de",
      port            => "13327",
      mapw            => 13,
      maph            => 13,
      max_outstanding => 2,
      token           => "a0",
      ncom            => [0..255],
      client          => "Crossfire Perl Module $VERSION $] $^O $0",
      tilesize        => 32,
      @_
   }, $class;

   $self->{fh} = new IO::Socket::INET PeerHost => $self->{host}, PeerPort => $self->{port}
      or die "$self->{host}:$self->{port}: $!";
   $self->{fh}->blocking (0); # stupid nonblock default

   my $buf;

   $self->{w} = AnyEvent->io (fh => $self->{fh}, poll => 'r', cb => sub {
      if (0 < sysread $self->{fh}, $buf, 16384, length $buf) {
         for (;;) {
            last unless 2 <= length $buf;
            my $len = unpack "n", $buf;
            last unless $len + 2 <= length $buf;

            substr $buf, 0, 2, "";
            $self->feed (substr $buf, 0, $len, "");
         }
      } else {
         $self->feed_eof;
      }
   });

   $self->{setup} = {
      sound             => 1,
      exp64             => 1,
      map1acmd          => 1,
      itemcmd           => 2,
      darkness          => 1,
      facecache         => 1,
      newmapcmd         => 1,
      mapinfocmd        => 1,
      extcmd            => 1,
      extendedTextInfos => 1,
      spellmon          => 1,
      fxix              => 1,
      excmd             => 1,
      msg               => 1,
      %{$self->{setup_req} || {} },
   };

   $self->send ("version 1023 1027 $self->{client}");

   # send initial setup req
   ++$self->{setup_outstanding};
   $self->send (join " ", "setup",
      %{$self->{setup}},
      mapsize => "$self->{mapw}x$self->{maph}",
   );

   $self->send ("requestinfo skill_info");
   $self->send ("requestinfo spell_paths");

   $self
}

sub token {
   ++$_[0]{token}
}

sub feed {
   my ($self, $data) = @_;

   $data =~ s/^([^ ]+)(?: |$)//
      or return;

   my $cb = $self->can ("feed_$1")
      or return; # ignore unknown commands

   $cb->($self, $data);

   warn $@ if $@;
}

sub feed_goodbye {
   my ($self) = @_;

   # nop
}

sub feed_version {
   my ($self, $version) = @_;

   chomp $version;

   $self->{version} = $version;
}

=back

=head2 METHODS THAT CAN/MUST BE OVERWRITTEN

=over 4

=item $self->setup_req (key => value)

Send a setup request for the given setting.

=item $self->setup_chk ($changed_setup)

Called when a setup reply is received from the server.

=item $self->setup ($setup)

Called after the last setup packet has been received, just before an addme
request is sent.

=cut

sub setup { }

sub setup_req {
   my ($self, $k, $v) = @_;

   $self->{setup_req}{$k} = $v;

   ++$self->{setup_outstanding};
   $self->send ("setup $k $v");
}

sub setup_chk {
   my ($self, $setup) = @_;

   if ($setup->{extendedTextInfos} > 0) {
      $self->send ("toggleextendedtext 1"); # books
      $self->send ("toggleextendedtext 2"); # cards
      $self->send ("toggleextendedtext 3"); # papers
      $self->send ("toggleextendedtext 4"); # signs
      $self->send ("toggleextendedtext 5"); # monuments
      #$self->send ("toggleextendedtext 6"); # scripted dialogs (yeah)
      $self->send ("toggleextendedtext 7"); # motd
   }

   if (exists $setup->{smoothing}) {
      $self->{smoothing} = $setup->{smoothing} > 0;
   }

   if (exists $setup->{mapsize}) {
      my ($mapw, $maph) = split /x/, $setup->{mapsize};

      if ($mapw != $self->{mapw} || $maph != $self->{maph}) {
         ($self->{mapw}, $self->{maph}) = ($mapw, $maph);

         # 2.x servers do not suffer from the stupid
         # mapsize-returns-two-things semantics anymore
         $self->setup_req (mapsize => "$self->{mapw}x$self->{maph}")
            unless $self->{setup}{extcmd} > 0;
      }
   }
}

sub feed_setup {
   my ($self, $data) = @_;

   $data =~ s/^ +//;

   my $changed = { split / +/, $data };

   $self->{setup} = { %{ $self->{setup} }, %$changed };
   $self->setup_chk ($changed);

   unless (--$self->{setup_outstanding}) {
      # done with negotiation

      $self->setup ($self->{setup});

      # servers supporting exticmd do sensible bandwidth management
      $self->{max_outstanding} = 512 if $self->{setup}{extcmd} > 0;

      $self->send ("addme");
      $self->feed_newmap;
   }
}

sub feed_eof {
   my ($self) = @_;

   delete $self->{w};
   close delete $self->{fh};

   for my $tag (sort { $b <=> $a } %{ $self->{container} || {} }) {
      $self->_del_items (values %{ $self->{container}{$tag} });
      $self->container_clear ($tag);
   }

   $self->eof;
}

sub feed_addme_success {
   my ($self, $data) = @_;

   $self->addme_success ($data);
}

sub feed_addme_failure {
   my ($self, $data) = @_;

   $self->addme_failure ($data);
}

sub logout {
   my ($self) = @_;

   $self->{fh} or return;

   $self->feed_eof;
}

sub destroy {
   my ($self) = @_;

   $self->logout;

   %$self = ();
}

=item $self->addme_success

=item $self->addme_failure

=item $self->eof

=cut

sub addme_success { }
sub addme_failure { }
sub eof           { }

sub feed_face1 {
   my ($self, $data) = @_;

   my ($num, $chksum, $name) = unpack "nNa*", $data;

   $self->need_face ($num, $name, $chksum);
}

sub feed_fx {
   my ($self, $data) = @_;

   my @info = unpack "(w C/a)*", $data;
   while (@info) {
      my $chksum  = pop @info;
      my $facenum = pop @info;

      $self->need_face ($facenum, (unpack "H*", $chksum), 0);
   }
}

=item $self->smooth_update ($facenum, $face)

=cut

sub smooth_update { }

sub feed_sx {
   my ($self, $data) = @_;

   my @info = unpack "(w w w)*", $data;
   while (@info) {
      my $level   = pop @info;
      my $smooth  = pop @info;
      my $facenum = pop @info;


      my $face = $self->{face}[$facenum];

      $face->{smoothface}  = $smooth;
      $face->{smoothlevel} = $level;

      $self->smooth_update ($facenum, $face);
   }
}

sub need_face {
   my ($self, $num, $name, $chksum) = @_;

   my $face = $self->{face}[$num] = { name => $name, chksum => $chksum };

   $self->face_find ($num, $face, sub {
      my ($data) = @_;
      if (length $data) {
         $face->{image} = $data;
         $self->face_update ($num, $face, 0);
      } else {
         $self->send_queue ("askface $num");
      }
   });
}

=item $conn->anim_update ($num) [OVERWRITE]

=cut

sub anim_update { }

sub feed_anim {
   my ($self, $data) = @_;

   my ($num, $flags, @faces) = unpack "n*", $data;

   $self->{anim}[$num] = \@faces;

   $self->anim_update ($num);
}

=item $conn->sound_play ($x, $y, $soundnum, $type)

=cut

sub sound_play { }

sub feed_sound {
   my ($self, $data) = @_;

   $self->sound_play (unpack "ccnC", $data);
}

=item $conn->query ($flags, $prompt)

=cut

sub query { }

sub feed_query {
   my ($self, $data) = @_;

   my ($flags, $prompt) = split /\s+/, $data, 2;

   if ($flags == 0 && $prompt =~ /What is your name\?/ && length $self->{user}) {
      if ($self->{sent_login}) {
         delete $self->{user};
         delete $self->{pass};
         $self->query ($flags, $prompt);
      } else {
         $self->send ("reply $self->{user}");
         $self->{sent_login} = 1;
      }
   } elsif ($flags == 4 && $prompt =~ /What is your password\?/ && length $self->{pass}) {
      $self->send ("reply $self->{pass}");
   } elsif ($flags == 4 && $prompt =~ /Please type your password again\./ && length $self->{pass}) {
      $self->send ("reply $self->{pass}");
   } else {
      $self->query ($flags, $prompt);
   }
}

=item $conn->drawextinfo ($color, $type, $subtype, $message)

default implementation calls msg

=item $conn->drawinfo ($color, $text)

default implementation calls msg

=item $conn->msg ($default_color, $type, $text, @extra)

=cut

sub drawextinfo {
   my ($self, $color, $type, $subtype, $message) = @_;

   for ($message) {
      s/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g;

      1 while s{ \[b\] (.*?) \[/b\] }{<b>$1</b>}igx;
      1 while s{ \[i\] (.*?) \[/i\] }{<i>$1</i>}igx;
      1 while s{ \[ul\](.*?) \[/ul\]}{<u>$1</u>}igx;
      1 while s{ \[fixed\](.*?)\[/fixed\]}{<tt>$1</tt>}igx;
      1 while s{ \[color=(.*?)\] (.*?) \[/color\]}{<span foreground='$1'>$2</span>}igx;

      #TODO: arcance, hand, strange, print font tags
      1 while s{ \[arcane\]  (.*?) \[/arcane\]  }{<i>$1</i>}igx;
      1 while s{ \[hand\]    (.*?) \[/hand\]    }{<i>$1</i>}igx;
      1 while s{ \[strange\] (.*?) \[/strange\] }{<i>$1</i>}igx;
      1 while s{ \[print\]   (.*?) \[/print\]   }{$1}igx;

   }

   $self->msg ($color, $type, $message, $subtype);
}

sub drawinfo {
   my ($self, $color, $text) = @_;

   for ($text) {
      s/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g;
   }

   $self->msg ($color, 0, $text);
}

sub msg { }

sub feed_ExtendedTextSet {
   my ($self, $data) = @_;
}

sub feed_drawextinfo {
   my ($self, $data) = @_;

   my ($color, $type, $subtype, $text) = split /\s+/, $data, 4;

   utf8::decode $text;
   $self->drawextinfo ($color, $type, $subtype, $text);
}

sub feed_drawinfo {
   my ($self, $data) = @_;

   my ($flags, $text) = split / /, $data, 2;

   utf8::decode $text;

   $self->drawinfo ($flags, $text);
}

sub feed_msg {
   my ($self, $data) = @_;

   if ($data =~ /^\s*\[/) {
      $self->msg (@{ from_json $data });
   } else {
      utf8::decode $data;
      $self->msg (split /\s+/, $data, 3);
   }
}

=item $conn->ex ($tag, $cb)

=cut

sub feed_ex {
   my ($self, $data) = @_;

   my ($tag, $text) = unpack "wa*", $data;

   if (my $q = delete $self->{cb_ex}{$tag}) {
      $_->($text, $tag) for @$q;
   }
}

sub ex {
   my ($self, $tag, $cb) = @_;

   return unless $self->{setup}{excmd} > 0;

   my $q = $self->{cb_ex}{$tag} ||= [];
   push @$q, $cb;
   $self->send ("ex $tag") if @$q == 1;
}

=item $conn->player_update ($player)

tag, weight, face, name

=cut

sub logged_in { }

sub player_update { }

sub feed_player {
   my ($self, $data) = @_;

   delete $self->{sent_login};

   # since the server never sends a "you have logged in" of any kind
   # we rely on being send "player" only once - after log-in.
   $self->logged_in;

   my ($tag, $weight, $face, $name) = unpack "NNN C/a", $data;

   $self->player_update ($self->{player} = {
      tag    => $tag,
      weight => $weight,
      face   => $face,
      name   => $name,
   });
}

=item $conn->stats_update ($stats)

=cut

sub stats_update { }

my %stat_32bit = map +($_ => 1),
   CS_STAT_WEIGHT_LIM,
   CS_STAT_SPELL_ATTUNE,
   CS_STAT_SPELL_REPEL,
   CS_STAT_SPELL_DENY,
   CS_STAT_EXP;

sub feed_stats {
   my ($self, $data) = @_;

   while (length $data) {
      my $stat = unpack "C", substr $data, 0, 1, "";
      my $value;

      if ($stat_32bit{$stat}) {
         $value = unpack "N", substr $data, 0, 4, "";
      } elsif ($stat == CS_STAT_SPEED || $stat == CS_STAT_WEAP_SP) {
         $value = (1 / FLOAT_MULTF) * unpack "N", substr $data, 0, 4, "";
      } elsif ($stat == CS_STAT_RANGE || $stat == CS_STAT_TITLE) {
         my $len = unpack "C", substr $data, 0, 1, "";
         $value = substr $data, 0, $len, "";
      } elsif ($stat == CS_STAT_EXP64) {
         my ($hi, $lo) = unpack "NN", substr $data, 0, 8, "";
         $value = $hi * 2**32 + $lo;
      } elsif ($stat >= CS_STAT_SKILLINFO && $stat < CS_STAT_SKILLINFO + CS_NUM_SKILLS) {
         my ($level, $hi, $lo) = unpack "CNN", substr $data, 0, 9, "";
         $value = [$level, $hi * 2**32 + $lo];
      } else {
         $value = unpack "s", pack "S", unpack "n", substr $data, 0, 2, "";
      }

      $self->{stat}{$stat} = $value;
   }

   $self->stats_update ($self->{stat});
}

=item $conn->container_add ($id, $item...)

=item $conn->container_clear ($id)

=item $conn->item_update ($item)

=item $conn->item_delete ($item...)

=cut

sub container_add { }
sub container_clear { }
sub item_delete { }
sub item_update { }

sub _del_items {
   my ($self, @items) = @_;

   for my $item (@items) {
      next if $item->{tag} == $self->{player}{tag};
      delete $self->{container}{$item->{container}}{$item+0};
      delete $self->{item}{$item->{tag}};
   }
}

sub feed_delinv {
   my ($self, $data) = @_;

   $self->_del_items (values %{ $self->{container}{$data} });
   $self->container_clear ($data);
}

sub feed_delitem {
   my ($self, $data) = @_;

   my @items = map $self->{item}{$_}, unpack "N*", $data;

   $self->_del_items (@items);
   $self->item_delete (@items);
}

my $count = 0;

sub feed_item2 {
   my ($self, $data) = @_;

   my ($location, @values) = unpack "N (NNNN C/a* nC Nn)*", $data;

   my @items;

   my $NOW = time;

   while (@values) {
      my ($tag, $flags, $weight, $face, $names, $anim, $animspeed, $nrof, $type) =
         splice @values, 0, 9, ();

      $weight = unpack "l", pack "L", $weight; # weight can be -1

      utf8::decode $names;
      my ($name, $name_pl) = split /\x00/, $names;

      my $item = {
         container => $location,
         tag       => $tag,
         flags     => $flags,
         weight    => $weight,
         face      => $face,
         name      => $name,
         name_pl   => $name_pl,
         anim      => $anim,
         animspeed => $animspeed * TICK,
         nrof      => $nrof,
         type      => $type,
         count     => ++$count,
         mtime     => $NOW,
         ctime     => $NOW,
      };

      if ($tag == $self->{player}{tag}) {
         $self->player_update ($self->{player} = $item);
      } else {
         if (my $prev = $self->{item}{$tag}) {
            $self->_del_items ($prev);
            $self->item_delete ($prev);
         }

         $self->{item}{$tag} = $item;
         $self->{container}{$location}{$item+0} = $item;
         push @items, $item;
      }
   }

  $self->container_add ($location, \@items);
}

sub feed_upditem {
   my ($self, $data) = @_;

   my ($flags, $tag) = unpack "CN", substr $data, 0, 5, "";

   my $item;
   if ($tag == $self->{player}{tag}) {
      $item = $self->{player};
   } else {
      $item = $self->{item}{$tag};
   }

   if ($flags & UPD_LOCATION) {
      $self->item_delete ($item);
      delete $self->{container}{$item->{container}}{$item+0};
      $item->{container} = unpack "N", substr $data, 0, 4, "";
      $self->{container}{$item->{container}}{$item+0} = $item;
      $self->container_add ($item->{location}, $item);
   }

   $item->{flags}  =                       unpack "N", substr $data, 0, 4, "" if $flags & UPD_FLAGS;
   $item->{weight} = unpack "l", pack "L", unpack "N", substr $data, 0, 4, "" if $flags & UPD_WEIGHT;
   $item->{face}   =                       unpack "N", substr $data, 0, 4, "" if $flags & UPD_FACE;

   if ($flags & UPD_NAME) {
      my $len = unpack "C", substr $data, 0, 1, "";

      my $names = substr $data, 0, $len, "";
      utf8::decode $names;
      @$item{qw(name name_pl)} = split /\x00/, $names;
   }

   $item->{anim}   = unpack "n", substr $data, 0, 2, "" if $flags & UPD_ANIM;
   $item->{animspeed} = TICK * unpack "C", substr $data, 0, 1, "" if $flags & UPD_ANIMSPEED;
   $item->{nrof}   = unpack "N", substr $data, 0, 4, "" if $flags & UPD_NROF;

   $item->{mtime} = time;

   if ($item->{tag} == $self->{player}{tag}) {
      $self->player_update ($self->{player} = $item);
   } else {
      $self->item_update ($item);
   }
}

=item $conn->spell_add ($spell)

      $spell = {
         tag          => ...,
         level        => ...,
         casting_time => ...,
         mana         => ...,
         grace        => ...,
         damage       => ...,
         skill        => ...,
         path         => ...,
         face         => ...,
         name         => ...,
         message      => ...,
      };

=item $conn->spell_update ($spell)

(the default implementation calls delete then add)

=item $conn->spell_delete ($spell)

=cut

sub spell_add { }

sub spell_update {
   my ($self, $spell) = @_;

   $self->spell_delete ($spell);
   $self->spell_add ($spell);
}

sub spell_delete { }

sub feed_addspell {
   my ($self, $data) = @_;

   my @data = unpack "(NnnnnnCNN C/a n/a)*", $data;

   while (@data) {
      my $spell = {
         tag          => (shift @data),
         level        => (shift @data),
         casting_time => (shift @data),
         mana         => (shift @data),
         grace        => (shift @data),
         damage       => (shift @data),
         skill        => (shift @data),
         path         => (shift @data),
         face         => (shift @data),
         name         => (shift @data),
         message      => (shift @data),
      };

      $self->send ("requestinfo image_sums $spell->{face} $spell->{face}")
         unless $self->{spell_face}[$spell->{face}]++;

      $self->spell_add ($self->{spell}{$spell->{tag}} = $spell);
   }
}

sub feed_updspell {
   my ($self, $data) = @_;

   my ($flags, $tag) = unpack "CN", substr $data, 0, 5, "";

   # only 1, 2, 4 supported
   # completely untested
   
   my $spell = $self->{spell}{$tag};

   $spell->{mana}   = unpack "n", substr $data, 0, 2, "" if $flags & UPD_SP_MANA;
   $spell->{grace}  = unpack "n", substr $data, 0, 2, "" if $flags & UPD_SP_GRACE;
   $spell->{damage} = unpack "n", substr $data, 0, 2, "" if $flags & UPD_SP_DAMAGE;
   
   $self->spell_update ($spell);
}

sub feed_delspell {
   my ($self, $data) = @_;

   $self->spell_delete (delete $self->{spell}{unpack "N", $data});
}

=item $conn->magicmap ($w, $h, $px, $py, $data)

=item $conn->map_change ($type, ...)

=cut

sub feed_magicmap {
   my ($self, $data) = @_;

   my ($w, $h, $x, $y, $data) = split / /, $data, 5;

   $self->magicmap ($w, $h, $x, $y, $data);
}

sub feed_map1a {
   my ($self, $data) = @_;
}

sub feed_map_scroll {
   my ($self, $data) = @_;

#   my ($dx, $dy) = split / /, $data;
}

sub feed_newmap {
   my ($self) = @_;

   $self->map_clear;
}

sub feed_map_scroll {
   my ($self, $data) = @_;

   my ($dx, $dy) = split / /, $data;

   $self->{delayed_scroll_x} += $dx;
   $self->{delayed_scroll_y} += $dy;

   $self->map_scroll ($dx, $dy);
}

sub map_change { }

sub feed_mapinfo {
   my ($self, $data) = @_;
   
   my ($token, @data) = split / /, $data;

   (delete $self->{mapinfo_cb}{$token})->(@data)
      if $self->{mapinfo_cb}{$token};

   $self->map_change (@data) if $token eq "-";
}

sub send_mapinfo {
   my ($self, $data, $cb) = @_;

   my $token = $self->token;

   $self->{mapinfo_cb}{$token} = sub {
      $self->send_queue;
      $cb->(@_);
   };
   $self->send_queue ("mapinfo $token $data");
}

sub feed_image {
   my ($self, $data) = @_;

   my ($num, $len, $data) = unpack "NNa*", $data;

   $self->send_queue;
   $self->{face}[$num]{image} = $data;
   $self->face_update ($num, $self->{face}[$num], 1);
   $self->map_update;
}

sub feed_ix {
   my ($self, $data) = @_;

   my ($num, $ofs, $data) = unpack "w w a*", $data;

   # void stupid substr out of range error
   $self->{ix_recv_buf} = " " x $ofs unless exists $self->{ix_recv_buf};
   substr $self->{ix_recv_buf}, $ofs, (length $data), $data;

   unless ($ofs) {
      $self->send_queue;
      $self->{face}[$num]{image} = delete $self->{ix_recv_buf};
      $self->face_update ($num, $self->{face}[$num], 1);
      $self->map_update;
   }
}

=item $conn->image_info ($numfaces, $chksum, [...image-sets])

=cut

sub image_info { }

sub feed_replyinfo {
   my ($self, $data) = @_;

   if ($data =~ s/^image_sums \d+ \d+ //) {
      eval {
         my ($num, $chksum, $faceset, $name) = unpack "n N C C/Z*", $data;

         $self->need_face ($num, $name, $chksum);
      };

   } elsif ($data =~ s/^image_info\s+//) {
      $self->image_info (split /\n/, $data);

   } elsif ($data =~ s/^skill_info\s+//) {
      for (split /\012/, $data) {
         my ($id, $name) = split /:/, $_, 2;
         $self->{skill_info}{$id} = $name;
      }

   } elsif ($data =~ s/^spell_paths\s+//) {
      for (split /\012/, $data) {
         my ($id, $name) = split /:/, $_, 2;
         $self->{spell_paths}{$id} = $name;
      }
   }
}

=item $conn->map_change ($mode, ...) [OVERWRITE]

   current <flags> <x> <y> <width> <height> <hashstring>

=cut

sub map_info { }

=item $conn->map_clear [OVERWRITE]

Called whenever the map is to be erased completely.

=cut

sub map_clear  { }

=item $conn->map_update ([ [x,y], [x,y], ...]) [OVERWRITE]

Called with a list of x|y coordinate pairs (as arrayrefs) for cells that
have been updated and need refreshing.

=cut

sub map_update { }

=item $conn->map_scroll ($dx, $dy) [OVERWRITE]

Called whenever the map has been scrolled.

=cut

sub map_scroll { }

=item $conn->face_update ($facenum, $facedata, $changed) [OVERWRITE]

Called with the face number of face structure whenever a face image
becomes known (either because C<face_find> returned it, in which case
C<$changed> is false, or because we got an update, in which case
C<$changed> is true).

=cut

sub face_update { }

=item $conn->face_find ($facenum, $facedata, $cb) [OVERWRITE]

Find and pass to the C<$cb> callback the png image data for the given
face, or the empty list if no face could be found, in which case it will
be requested from the server.

=cut

sub face_find { }

=item $conn->send ($data)

Send a single packet/line to the server.

=cut

sub send {
   my ($self, $data) = @_;

   $data = pack "na*", length $data, $data;

   syswrite $self->{fh}, $data;
}

=item $conn->send_command ($command[, $cb1[, $cb2]])

Uses either command or ncom to send a user-level command to the
server. Encodes the command to UTF-8.

If the server supports a fixed version of the ncom command and this is
detected by this module, the following is also supported:

If the callback C<$cb1> is given, calls it with the absolute time when
this command has finished processing, as soon as this information is
available.

If the callback C<$cb2> is given it will be called when the command has
finished processing, to the best knowledge of this module :)

=cut

sub feed_comc {
   my ($self, $data) = @_;

   my ($tag, $time) = unpack "nN", $data;

   push @{ $self->{ncom} }, $tag;
}

sub send_command {
   my ($self, $command, $cb1, $cb2) = @_;

   utf8::encode $command;

   if (0 && (my $tag = pop @{ $self->{ncom} })) {
      $self->send (pack "A* n N a*", "ncom ", $tag, 1, $command);
      $cb1->(0) if $cb1;
      $cb2->()  if $cb2;
   } else {
      $self->send ("command $command");
      $cb1->(0) if $cb1;
      $cb2->()  if $cb2;
   }
}

sub send_queue {
   my ($self, $cmd) = @_;

   if (defined $cmd) {
      push @{ $self->{send_queue} }, $cmd;
   } else {
      --$self->{outstanding};
   }

   if ($self->{outstanding} < $self->{max_outstanding} && @{ $self->{send_queue} }) {
      ++$self->{outstanding};
      $self->send (shift @{ $self->{send_queue} });
   }
}

sub connect_ext {
   my ($self, $type, $cb) = @_;

   $self->{extcmd_cb_type}{$type} = $cb;
}

sub disconnect_ext {
   my ($self, $type) = @_;

   delete $self->{extcmd_cb_type}{$type};
}

sub feed_ext {
   my ($self, $data) = @_;

   my $msg = eval { from_json $data }
      or return;

   my $cb = $self->{extcmd_cb_id}{$msg->{msgid}} || $self->{extcmd_cb_type}{$msg->{msgtype}}
      or return;

   $cb->($msg)
      or delete $self->{extcmd_cb_id}{$msg->{msgid}};
}

sub send_ext_msg {
   my ($self, $type, %msg) = @_;

   $msg{msgtype} = $type;

   $self->send ("ext " . to_json \%msg);
}

sub send_ext_req {
   my $cb = pop; # callback is last
   my ($self, $type, %msg) = @_;

   if ($self->{setup}{extcmd} > 0) {
      my $id = $self->token;
      $self->{extcmd_cb_id}{$id} = $cb;
      $self->send_ext_msg ($type, %msg, msgid => $id);

      return $id;
   } else {
      $cb->(); # == not supported by server

      return;
   }
}

=back

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

 Robin Redeker <elmex@ta-sa.org>
 http://www.ta-sa.org/

=cut

1
