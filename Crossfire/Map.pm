=head1 NAME

Crossfire::Map - represent a crossfire map

=cut

package Crossfire::Map;

our $VERSION = '0.1';

use strict;

use Carp ();
use Crossfire;

use base 'Exporter';

sub new {
   my ($class, $width, $height) = @_;

   bless { info => { _name => 'map' }, width => $width, height => $height }, $class
}

sub new_from_file  {
   new_from_archlist {$_[0]} read_arch $_[1]
}

sub new_from_archlist {
   my ($class, $mapa) = @_;

   my %meta;

   my ($mapx, $mapy);

   my $map;

   for (@{ $mapa->{arch} }) {
      my ($x, $y) = (delete $_->{x}, delete $_->{y});

      if ($_->{_name} eq "map") {
         $meta{info} = $_;

         $mapx = $_->{width}  || $x;
         $mapy = $_->{height} || $y;
      } else {
         push @{ $map->[$x][$y] }, $_;

         # arch map is unreliable w.r.t. width and height
         $mapx = $x + 1 if $mapx <= $x;
         $mapy = $y + 1 if $mapy <= $y;
         #$mapx = $a->{x} + 1, warn "$mapname: arch '$a->{_name}' outside map width at ($a->{x}|$a->{y})\n" if $mapx <= $a->{x};
         #$mapy = $a->{y} + 1, warn "$mapname: arch '$a->{_name}' outside map height at ($a->{x}|$a->{y})\n" if $mapy <= $a->{y};
      }
   }

   $meta{width}  = $mapx;
   $meta{height} = $mapy;
   $meta{map}    = $map;

   bless \%meta, $class
}

sub new_pickmap {
   my ($class, $archs, $width) = @_;

   # sort archs alphabetically
   my $archs = [ sort { $a->{_name} cmp $b->{_name} } @$archs ];

   $width ||= 10; # default width

   my $num = @$archs;
   my $map = { };
   # overall placement coords
   my $x = 0; 
   my $y = 0;

   my ($maxh, $maxw) = (0, 0); # maximum sizes, to set map width/height later
   my $max_line_height = 1;

   for (my $i = 0; $i < $num; $i++) {
      # check whether this tile was already written (see below at (b))
      unless (defined $map->{map}[$x][$y]) {
         my ($x1, $y1, $x2, $y2) = arch_extents $archs->[$i];

         if ($x + $x2 - $x1 + 1 > $width) {
            $y += $max_line_height;
            $max_line_height = 1;
            $x = 0;
         }

         $map->{map}[$x - $x1][$y - $y1] = [$archs->[$i]];

         $x += $x2 - $x1 + 1;

         $max_line_height = List::Util::max $max_line_height, $y2 - $y1 + 1;

      } else {
         $i--;
      }

      $maxw = List::Util::max $maxw, $x;
      $maxh = List::Util::max $maxh, $y + $max_line_height;
   }

   $map->{height} = $maxh;
   $map->{width}  = $maxw;

   $map
}

sub resize {
   my ($self, $width, $height) = @_;

   $self->{width}  = $width;
   $self->{height} = $height;

   # i am sure this can be done more elegantly
   @{$self->{map}} = @{$self->{map}}[0 .. $width - 1];

   for (@{$self->{map}}) {
      @$_ = @$_[0 .. $height - 1];
   }
}

sub as_archlist {
   my ($self) = @_;

   # wing map so we have no extra-map arches
   $self->resize ($self->{width}, $self->{height});

   my @arch;

   for my $x (0 .. $self->{width} - 1) {
      my $ass = $self->{map}[$x];
      for my $y (0 .. $self->{height} - 1) {
         for my $a (@{ $ass->[$y] || [] }) {
            next if $a->{_virtual};

            # note: big faces _may_ span map boundaries

            my %a = %$a;
            delete $a{x};
            delete $a{y};
            $a{x} = $x if $x;
            $a{y} = $y if $y;

            push @arch, \%a;
         }
      }
   }

   # now assemble meta info
   if ($self->{info}) {
      my %meta = %{$self->{info}};

      $meta{width}  = $self->{width};
      $meta{height} = $self->{height};

      unshift @arch, Crossfire::normalize_arch \%meta;
   }

   \@arch
}

sub as_mapstring {
   my ($self) = @_;

   my $arch = $self->as_archlist;

   my $str;

   my $append; $append = sub {
      my %a = %{$_[0]};

      Crossfire::normalize_arch \%a;

      # undo the bit-split we did before
      if (exists $a{attack_movement_bits_0_3} or exists $a{attack_movement_bits_4_7}) {
         $a{attack_movement} = (delete $a{attack_movement_bits_0_3})
                             | (delete $a{attack_movement_bits_4_7});
      }

      $str .= "arch $a{_name}\n";

      my $inv = delete $a{inventory};
      delete $a{more}; # arches do not support 'more', but old maps can contain some

      my @kv;

      for ($a{_name} eq "map"
           ? @Crossfire::FIELD_ORDER_MAP
           : @Crossfire::FIELD_ORDER) {
         push @kv, [$_, delete $a{$_}]
            if exists $a{$_};
      }

      for (sort keys %a) {
         next if /^_/; # ignore our _-keys
         push @kv, [$_, delete $a{$_}];
      }

      for (@kv) {
         my ($k, $v) = @$_;

         if (my $end = $Crossfire::FIELD_MULTILINE{$k}) {
            $v =~ s/\n$//;
            $str .= "$k\n$v\n$end\n";
         } elsif (exists $Crossfire::FIELD_MOVEMENT{$k}) {
            if ($v & ~Crossfire::MOVE_ALL or !$v) {
               $str .= "$k $v\n";

            } elsif ($v & Crossfire::MOVE_ALLBIT) {
               $str .= "$k all";

               $str .= " -walk"     unless $v & Crossfire::MOVE_WALK;
               $str .= " -fly_low"  unless $v & Crossfire::MOVE_FLY_LOW;
               $str .= " -fly_high" unless $v & Crossfire::MOVE_FLY_HIGH;
               $str .= " -swim"     unless $v & Crossfire::MOVE_SWIM;
               $str .= " -boat"     unless $v & Crossfire::MOVE_BOAT;

               $str .= "\n";

            } else {
               $str .= $k;

               $str .= " walk"     if $v & Crossfire::MOVE_WALK;
               $str .= " fly_low"  if $v & Crossfire::MOVE_FLY_LOW;
               $str .= " fly_high" if $v & Crossfire::MOVE_FLY_HIGH;
               $str .= " swim"     if $v & Crossfire::MOVE_SWIM;
               $str .= " boat"     if $v & Crossfire::MOVE_BOAT;

               $str .= "\n";
            }
         } else {
            $str .= "$k $v\n";
         }
      }

      if ($inv) {
         $append->($_) for @$inv;
      }

      $str .= "end\n";

   };
      
   for (@$arch) {
      $append->($_);
   }

   $str
}

sub write_file {
   my ($self, $path) = @_;

   open my $fh, ">:raw:utf8", "$path~" or Carp::croak "$path~: $!";
   print $fh $self->as_mapstring       or Carp::croak "$path~: $!";
   close $fh                           or Carp::croak "$path~: $!";

   if (stat $path) {
      chmod +(stat _)[2] & 0777, "$path~";
      chown +(stat _)[4,5], "$path~";
   }

   rename "$path~", $path;
}

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

 Robin Redeker <elmex@ta-sa.org>
 http://www.ta-sa.org/

=cut

1
