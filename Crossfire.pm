=head1 NAME

Crossfire - Crossfire maphandling

=cut

package Crossfire;

our $VERSION = '0.91';

use strict;

use base 'Exporter';

use Carp ();
use File::Spec;
use List::Util qw(min max);
use Storable qw(freeze thaw);

our @EXPORT = qw(
   read_pak read_arch *ARCH TILESIZE $TILE *FACE editor_archs arch_extents
);

use JSON::Syck (); #TODO#d# replace by JSON::PC when it becomes available == working

sub from_json($) {
   $JSON::Syck::ImplicitUnicode = 1;
   JSON::Syck::Load $_[0]
}

sub to_json($) {
   $JSON::Syck::ImplicitUnicode = 0;
   JSON::Syck::Dump $_[0]
}

our $LIB = $ENV{CROSSFIRE_LIBDIR};

our $VARDIR = $ENV{HOME} ? "$ENV{HOME}/.crossfire" : File::Spec->tmpdir . "/crossfire";

mkdir $VARDIR, 0777;

sub TILESIZE (){ 32 }

our %ARCH;
our %FACE;
our $TILE;

our %FIELD_MULTILINE = (
   msg     => "endmsg",
   lore    => "endlore",
   maplore => "endmaplore",
);

# movement bit type, PITA
our %FIELD_MOVEMENT = map +($_ => undef),
   qw(move_type move_block move_allow move_on move_off move_slow);

# same as in server save routine, to (hopefully) be compatible
# to the other editors.
our @FIELD_ORDER_MAP = (qw(
   name attach swap_time reset_timeout fixed_resettime difficulty region
   shopitems shopgreed shopmin shopmax shoprace
   darkness width height enter_x enter_y msg maplore
   unique template
   outdoor temp pressure humid windspeed winddir sky nosmooth
   tile_path_1 tile_path_2 tile_path_3 tile_path_4
));

our @FIELD_ORDER = (qw(
   elevation

   name name_pl custom_name attach title race
   slaying skill msg lore other_arch face
   #todo-events
   animation is_animated
   str dex con wis pow cha int
   hp maxhp sp maxsp grace maxgrace
   exp perm_exp expmul
   food dam luck wc ac x y speed speed_left move_state attack_movement
   nrof level direction type subtype attacktype

   resist_physical resist_magic resist_fire resist_electricity 
   resist_cold resist_confusion resist_acid resist_drain 
   resist_weaponmagic resist_ghosthit resist_poison resist_slow 
   resist_paralyze resist_turn_undead resist_fear resist_cancellation 
   resist_deplete resist_death resist_chaos resist_counterspell 
   resist_godpower resist_holyword resist_blind resist_internal 
   resist_life_stealing resist_disease

   path_attuned path_repelled path_denied material materialname
   value carrying weight invisible state magic
   last_heal last_sp last_grace last_eat
   connected glow_radius randomitems npx_status npc_program
   run_away pick_up container will_apply smoothlevel
   current_weapon_script weapontype tooltype elevation client_type
   item_power duration range
   range_modifier duration_modifier dam_modifier gen_sp_armour
   move_type move_block move_allow move_on move_off move_on move_slow move_slow_penalty

   alive wiz was_wiz applied unpaid can_use_shield no_pick is_animated monster
   friendly generator is_thrown auto_apply treasure player sold see_invisible
   can_roll overlay_floor is_turnable is_used_up identified reflecting changing
   splitting hitback startequip blocksview undead scared unaggressive
   reflect_missile reflect_spell no_magic no_fix_player is_lightable tear_down
   run_away pick_up unique no_drop can_cast_spell can_use_scroll can_use_range
   can_use_bow can_use_armour can_use_weapon can_use_ring has_ready_range
   has_ready_bow xrays is_floor lifesave no_strength sleep stand_still
   random_move only_attack confused stealth cursed damned see_anywhere
   known_magical known_cursed can_use_skill been_applied has_ready_scroll
   can_use_rod can_use_horn make_invisible inv_locked is_wooded is_hilly
   has_ready_skill has_ready_weapon no_skill_ident is_blind can_see_in_dark
   is_cauldron is_dust no_steal one_hit berserk neutral no_attack no_damage
   activate_on_push activate_on_release is_water use_content_on_gen is_buildable

   body_range body_arm body_torso body_head body_neck body_skill
   body_finger body_shoulder body_foot body_hand body_wrist body_waist
));

our %EVENT_TYPE = (
   apply   =>  1,
   attack  =>  2,
   death   =>  3,
   drop    =>  4,
   pickup  =>  5,
   say     =>  6,
   stop    =>  7,
   time    =>  8,
   throw   =>  9,
   trigger => 10,
   close   => 11,
   timer   => 12,
);

sub MOVE_WALK      (){ 0x01 }
sub MOVE_FLY_LOW   (){ 0x02 }
sub MOVE_FLY_HIGH  (){ 0x04 }
sub MOVE_FLYING    (){ 0x06 }
sub MOVE_SWIM      (){ 0x08 }
sub MOVE_BOAT      (){ 0x10 }
sub MOVE_KNOWN     (){ 0x1f } # all of above
sub MOVE_ALLBIT    (){ 0x10000 }
sub MOVE_ALL       (){ 0x1001f } # very special value, more PITA

sub load_ref($) {
   my ($path) = @_;

   open my $fh, "<:raw:perlio", $path
      or die "$path: $!";
   local $/;

   thaw <$fh>
}

sub save_ref($$) {
   my ($ref, $path) = @_;

   open my $fh, ">:raw:perlio", "$path~"
      or die "$path~: $!";
   print $fh freeze $ref;
   close $fh;
   rename "$path~", $path
      or die "$path: $!";
}

my %attack_mask = (
   physical      => 0x00000001,
   magic         => 0x00000002,
   fire          => 0x00000004,
   electricity   => 0x00000008,
   cold          => 0x00000010,
   confusion     => 0x00000020,
   acid          => 0x00000040,
   drain         => 0x00000080,
   weaponmagic   => 0x00000100,
   ghosthit      => 0x00000200,
   poison        => 0x00000400,
   slow          => 0x00000800,
   paralyze      => 0x00001000,
   turn_undead   => 0x00002000,
   fear          => 0x00004000,
   cancellation  => 0x00008000,
   deplete       => 0x00010000,
   death         => 0x00020000,
   chaos         => 0x00040000,
   counterspell  => 0x00080000,
   godpower      => 0x00100000,
   holyword      => 0x00200000,
   blind         => 0x00400000,
   internal      => 0x00800000,
   life_stealing => 0x01000000,
   disease       => 0x02000000,
);

sub _add_resist($$$) {
   my ($ob, $mask, $value) = @_;

   while (my ($k, $v) = each %attack_mask) {
      $ob->{"resist_$k"} = min 100, max -100, $ob->{"resist_$k"} + $value if $mask & $v;
   }
}

# object as in "Object xxx", i.e. archetypes
sub normalize_object($) {
   my ($ob) = @_;

   # nuke outdated or never supported fields
   delete @$ob{qw(
      can_knockback can_parry can_impale can_cut can_dam_armour
      can_apply pass_thru can_pass_thru
   )};

   if (my $mask = delete $ob->{immune}    ) { _add_resist $ob, $mask,  100; }
   if (my $mask = delete $ob->{protected} ) { _add_resist $ob, $mask,   30; }
   if (my $mask = delete $ob->{vulnerable}) { _add_resist $ob, $mask, -100; }

   # convert movement strings to bitsets
   for my $attr (keys %FIELD_MOVEMENT) {
      next unless exists $ob->{$attr};

      $ob->{$attr} = MOVE_ALL if $ob->{$attr} == 255; #d# compatibility

      next if $ob->{$attr} =~ /^\d+$/;

      my $flags = 0;

      # assume list
      for my $flag (map lc, split /\s+/, $ob->{$attr}) {
         $flags |=  MOVE_WALK     if $flag eq "walk";
         $flags |=  MOVE_FLY_LOW  if $flag eq "fly_low";
         $flags |=  MOVE_FLY_HIGH if $flag eq "fly_high";
         $flags |=  MOVE_FLYING   if $flag eq "flying";
         $flags |=  MOVE_SWIM     if $flag eq "swim";
         $flags |=  MOVE_BOAT     if $flag eq "boat";
         $flags |=  MOVE_ALL      if $flag eq "all";

         $flags &= ~MOVE_WALK     if $flag eq "-walk";
         $flags &= ~MOVE_FLY_LOW  if $flag eq "-fly_low";
         $flags &= ~MOVE_FLY_HIGH if $flag eq "-fly_high";
         $flags &= ~MOVE_FLYING   if $flag eq "-flying";
         $flags &= ~MOVE_SWIM     if $flag eq "-swim";
         $flags &= ~MOVE_BOAT     if $flag eq "-boat";
         $flags &= ~MOVE_ALL      if $flag eq "-all";
      }

      $ob->{$attr} = $flags;
   }

   # convert outdated movement flags to new movement sets
   if (defined (my $v = delete $ob->{no_pass})) {
      $ob->{move_block} = $v ? MOVE_ALL : 0;
   }
   if (defined (my $v = delete $ob->{slow_move})) {
      $ob->{move_slow} |= MOVE_WALK;
      $ob->{move_slow_penalty} = $v;
   }
   if (defined (my $v = delete $ob->{walk_on})) {
      $ob->{move_on} = MOVE_ALL unless exists $ob->{move_on};
      $ob->{move_on} = $v ? $ob->{move_on} | MOVE_WALK
                          : $ob->{move_on} & ~MOVE_WALK;
   }
   if (defined (my $v = delete $ob->{walk_off})) {
      $ob->{move_off} = MOVE_ALL unless exists $ob->{move_off};
      $ob->{move_off} = $v ? $ob->{move_off} | MOVE_WALK
                           : $ob->{move_off} & ~MOVE_WALK;
   }
   if (defined (my $v = delete $ob->{fly_on})) {
      $ob->{move_on} = MOVE_ALL unless exists $ob->{move_on};
      $ob->{move_on} = $v ? $ob->{move_on} | MOVE_FLY_LOW
                          : $ob->{move_on} & ~MOVE_FLY_LOW;
   }
   if (defined (my $v = delete $ob->{fly_off})) {
      $ob->{move_off} = MOVE_ALL unless exists $ob->{move_off};
      $ob->{move_off} = $v ? $ob->{move_off} | MOVE_FLY_LOW
                           : $ob->{move_off} & ~MOVE_FLY_LOW;
   }
   if (defined (my $v = delete $ob->{flying})) {
      $ob->{move_type} = MOVE_ALL unless exists $ob->{move_type};
      $ob->{move_type} = $v ? $ob->{move_type} | MOVE_FLY_LOW
                            : $ob->{move_type} & ~MOVE_FLY_LOW;
   }

   # convert idiotic event_xxx things into objects
   while (my ($event, $subtype) = each %EVENT_TYPE) {
      if (exists $ob->{"event_${event}_plugin"}) {
         push @{$ob->{inventory}}, {
            _name   => "event_$event",
            title   => delete $ob->{"event_${event}_plugin"},
            slaying => delete $ob->{"event_${event}"},
            name    => delete $ob->{"event_${event}_options"},
         };
      }
   }

   # some archetypes had "+3" instead of the canonical "3", so fix
   $ob->{dam} *= 1 if exists $ob->{dam};

   $ob
}

# arch as in "arch xxx", ie.. objects
sub normalize_arch($) {
   my ($ob) = @_;

   normalize_object $ob;

   my $arch = $ARCH{$ob->{_name}}
      or (warn "$ob->{_name}: no such archetype", return $ob);

   if ($arch->{type} == 22) { # map
      my %normalize = (
         "enter_x"         => "hp",
         "enter_y"         => "sp",
         "width"           => "x",
         "height"          => "y",
         "reset_timeout"   => "weight",
         "swap_time"       => "value",
         "difficulty"      => "level",
         "darkness"        => "invisible",
         "fixed_resettime" => "stand_still",
      );

      while (my ($k2, $k1) = each %normalize) {
         if (defined (my $v = delete $ob->{$k1})) {
            $ob->{$k2} = $v;
         }
      }
   } else {
      # if value matches archetype default, delete
      while (my ($k, $v) = each %$ob) {
         if (exists $arch->{$k} and $arch->{$k} eq $v) {
            next if $k eq "_name";
            delete $ob->{$k};
         }
      }
   }

   # a speciality for the editor
   if (exists $ob->{attack_movement}) {
      my $am = delete $ob->{attack_movement};
      $ob->{attack_movement_bits_0_3} = $am &  15;
      $ob->{attack_movement_bits_4_7} = $am & 240;
   }

   $ob
}

sub attr_thaw($) {
   my ($ob) = @_;

   $ob->{attach} = from_json $ob->{attach}
      if exists $ob->{attach};

   $ob
}

sub attr_freeze($) {
   my ($ob) = @_;

   $ob->{attach} = Crossfire::to_json $ob->{attach}
      if exists $ob->{attach};

   $ob
}

sub read_pak($) {
   my ($path) = @_;

   my %pak;

   open my $fh, "<:raw:perlio", $path
      or Carp::croak "$_[0]: $!";
   binmode $fh;
   while (<$fh>) {
      my ($type, $id, $len, $path) = split;
      $path =~ s/.*\///;
      read $fh, $pak{$path}, $len;
   }

   \%pak
}

sub read_arch($;$) {
   my ($path, $toplevel) = @_;

   my %arc;
   my ($more, $prev);

   open my $fh, "<:raw:perlio:utf8", $path
      or Carp::croak "$path: $!";

#  binmode $fh;

   my $parse_block; $parse_block = sub {
      my %arc = @_;

      while (<$fh>) {
         s/\s+$//;
         if (/^end$/i) {
            last;
         } elsif (/^arch (\S+)$/i) {
            push @{ $arc{inventory} }, attr_thaw normalize_arch $parse_block->(_name => $1);
         } elsif (/^lore$/i) {
            while (<$fh>) {
               last if /^endlore\s*$/i;
               $arc{lore} .= $_;
            }
         } elsif (/^msg$/i) {
            while (<$fh>) {
               last if /^endmsg\s*$/i;
               $arc{msg} .= $_;
            }
         } elsif (/^anim$/i) {
            while (<$fh>) {
               last if /^mina\s*$/i;
               chomp;
               push @{ $arc{anim} }, $_;
            }
         } elsif (/^(\S+)\s*(.*)$/) {
            $arc{lc $1} = $2;
         } elsif (/^\s*($|#)/) {
            #
         } else {
            warn "$path: unparsable line '$_' in arch $arc{_name}";
         }
      }

      \%arc
   };

   while (<$fh>) {
      s/\s+$//;
      if (/^more$/i) {
         $more = $prev;
      } elsif (/^object (\S+)$/i) {
         my $name = $1;
         my $arc = attr_thaw normalize_object $parse_block->(_name => $name);
         $arc->{_atype} = 'object';

         if ($more) {
            $more->{more} = $arc;
         } else {
            $arc{$name} = $arc;
         }
         $prev = $arc;
         $more = undef;
      } elsif (/^arch (\S+)$/i) {
         my $name = $1;
         my $arc = attr_thaw normalize_arch $parse_block->(_name => $name);
         $arc->{_atype} = 'arch';

         if ($more) {
            $more->{more} = $arc;
         } else {
            push @{ $arc{arch} }, $arc;
         }
         $prev = $arc;
         $more = undef;
      } elsif ($toplevel && /^(\S+)\s+(.*)$/) {
         if ($1 eq "lev_array") {
            while (<$fh>) {
               last if /^endplst\s*$/;
               push @{$toplevel->{lev_array}}, $_+0;
            }
         } else {
            $toplevel->{$1} = $2;
         }
      } elsif (/^\s*($|#)/) {
         #
      } else {
         die "$path: unparseable top-level line '$_'";
      }
   }

   undef $parse_block; # work around bug in perl not freeing $fh etc.

   \%arc
}

sub archlist_to_string {
   my ($arch) = @_;

   my $str;

   my $append; $append = sub {
      my %a = %{$_[0]};

      Crossfire::attr_freeze \%a;
      Crossfire::normalize_arch \%a;

      # undo the bit-split we did before
      if (exists $a{attack_movement_bits_0_3} or exists $a{attack_movement_bits_4_7}) {
         $a{attack_movement} = (delete $a{attack_movement_bits_0_3})
                             | (delete $a{attack_movement_bits_4_7});
      }

      $str .= ((exists $a{_atype}) ? $a{_atype} : 'arch'). " $a{_name}\n";

      my $inv = delete $a{inventory};
      my $more = delete $a{more}; # arches do not support 'more', but old maps can contain some
      my $anim = delete $a{anim};

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

      if ($a{_atype} eq 'object') {
         $str .= join "\n", "anim", @$anim, "mina\n"
            if $anim;
      }

      $str .= "end\n";

      if (($a{_atype} eq 'object') && $more) {
         $str .= "\nmore\n";
         $append->($more) if $more;
      }
   };

   for (@$arch) {
      $append->($_);
   }

   $str
}

# put all archs into a hash with editor_face as it's key
# NOTE: the arrays in the hash values are references to 
# the archs from $ARCH
sub editor_archs {
   my %paths;

   for (keys %ARCH) {
      my $arch = $ARCH{$_};
      push @{$paths{$arch->{editor_folder}}}, $arch;
   }

   \%paths
}

=item ($minx, $miny, $maxx, $maxy) = arch_extents $arch

arch_extents determines the extents of the given arch's face(s), linked
faces and single faces are handled here it returns (minx, miny, maxx,
maxy)

=cut

sub arch_extents {
   my ($a) = @_;

   my $o = $ARCH{$a->{_name}}
      or return;

   my $face = $FACE{$a->{face} || $o->{face} || "blank.111"}
      or (warn "no face data found for arch '$a->{_name}'"), return;

   if ($face->{w} > 1 || $face->{h} > 1) { 
      # bigface
      return (0, 0, $face->{w} - 1, $face->{h} - 1);

   } elsif ($o->{more}) {
      # linked face
      my ($minx, $miny, $maxx, $maxy) = ($o->{x}, $o->{y}) x 2;

      for (; $o; $o = $o->{more}) {
         $minx = min $minx, $o->{x};
         $miny = min $miny, $o->{y};
         $maxx = max $maxx, $o->{x};
         $maxy = max $maxy, $o->{y};
      }

      return ($minx, $miny, $maxx, $maxy);

   } else {
      # single face
      return (0, 0, 0, 0);
   }
}

=item $type = arch_attr $arch

Returns a hashref describing the object and its attributes. It can contain
the following keys:

   name   the name, suitable for display purposes
   ignore
   attr
   desc
   use
   section => [name => \%attr, name => \%attr]
   import

=cut

sub arch_attr($) {
   my ($obj) = @_;

   require Crossfire::Data;

   my $root;
   my $attr = { };
   
   my $arch = $ARCH{ $obj->{_name} };
   my $type = $obj->{type} || $arch->{type};

   if ($type > 0) {
      $root = $Crossfire::Data::ATTR{$type};
   } else {
      my %a = (%$arch, %$obj);

      if ($a{is_floor} && !$a{alive}) {
         $root = $Crossfire::Data::TYPE{Floor};
      } elsif (!$a{is_floor} && $a{alive} && !$a{tear_down}) {
         $root = $Crossfire::Data::TYPE{"Monster & NPC"};
      } elsif (!$a{is_floor} && !$a{alive} && $a{move_block}) {
         $root = $Crossfire::Data::TYPE{Wall};
      } elsif (!$a{is_floor} && $a{alive} && $a{tear_down}) {
         $root = $Crossfire::Data::TYPE{"Weak Wall"};
      } else {
         $root = $Crossfire::Data::TYPE{Misc};
      }
   }

   my @import = ($root);
   
   unshift @import, \%Crossfire::Data::DEFAULT_ATTR
      unless $type == 116;

   my (%ignore);
   my (@section_order, %section, @attr_order);

   while (my $type = shift @import) {
      push @import, @{$type->{import} || []};

      $attr->{$_} ||= $type->{$_}
         for qw(name desc use);

      for (@{$type->{ignore} || []}) {
         $ignore{$_}++ for ref $_ ? @$_ : $_;
      }

      for ([general => ($type->{attr} || [])], @{$type->{section} || []}) {
         my ($name, $attr) = @$_;
         push @section_order, $name;
         for (@$attr) {
            my ($k, $v) = @$_;
            push @attr_order, $k;
            $section{$name}{$k} ||= $v;
         }
      }
   }

   $attr->{section} = [
      map !exists $section{$_} ? () : do {
            my $attr = delete $section{$_};

            [
               $_,
               map exists $attr->{$_} && !$ignore{$_}
                      ? [$_ => delete $attr->{$_}] : (),
                   @attr_order
            ]
         },
         
         exists $section{$_} ? [$_ => delete $section{$_}] : (), 
         @section_order
   ];

   $attr
}

sub arch_edit_sections {
#      if (edit_type == IGUIConstants.TILE_EDIT_NONE)
#           edit_type = 0;
#       else if (edit_type != 0) {
#           // all flags from 'check_type' must be unset in this arch because they get recalculated now
#           edit_type &= ~check_type;
#       }
#
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_MONSTER) != 0 &&
#           getAttributeValue("alive", defarch) == 1 &&
#           (getAttributeValue("monster", defarch) == 1 ||
#           getAttributeValue("generator", defarch) == 1)) {
#           // Monster: monsters/npcs/generators
#           edit_type |= IGUIConstants.TILE_EDIT_MONSTER;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_WALL) != 0 &&
#           arch_type == 0 && getAttributeValue("no_pass", defarch) == 1) {
#           // Walls
#           edit_type |= IGUIConstants.TILE_EDIT_WALL;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_CONNECTED) != 0 &&
#           getAttributeValue("connected", defarch) != 0) {
#           // Connected Objects
#           edit_type |= IGUIConstants.TILE_EDIT_CONNECTED;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_EXIT) != 0 &&
#           arch_type == 66 || arch_type == 41 || arch_type == 95) {
#           // Exit: teleporter/exit/trapdoors
#           edit_type |= IGUIConstants.TILE_EDIT_EXIT;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_TREASURE) != 0 &&
#           getAttributeValue("no_pick", defarch) == 0 && (arch_type == 4 ||
#           arch_type == 5 || arch_type == 36 || arch_type == 60 ||
#           arch_type == 85 || arch_type == 111 || arch_type == 123 ||
#           arch_type == 124 || arch_type == 130)) {
#           // Treasure: randomtreasure/money/gems/potions/spellbooks/scrolls
#           edit_type |= IGUIConstants.TILE_EDIT_TREASURE;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_DOOR) != 0 &&
#           arch_type == 20 || arch_type == 23 || arch_type == 26 ||
#           arch_type == 91 || arch_type == 21 || arch_type == 24) {
#       // Door: door/special door/gates  + keys
#       edit_type |= IGUIConstants.TILE_EDIT_DOOR;
#       }
#       if ((check_type & IGUIConstants.TILE_EDIT_EQUIP) != 0 &&
#           getAttributeValue("no_pick", defarch) == 0 && ((arch_type >= 13 &&
#           arch_type <= 16) || arch_type == 33 || arch_type == 34 ||
#           arch_type == 35 || arch_type == 39 || arch_type == 70 ||
#           arch_type == 87 || arch_type == 99 || arch_type == 100 ||
#           arch_type == 104 || arch_type == 109 || arch_type == 113 ||
#           arch_type == 122 || arch_type == 3)) {
#           // Equipment: weapons/armour/wands/rods
#           edit_type |= IGUIConstants.TILE_EDIT_EQUIP;
#       }
#
#       return(edit_type);
#
#  
}

sub cache_file($$&&) {
   my ($src, $cache, $load, $create) = @_;

   my ($size, $mtime) = (stat $src)[7,9]
      or Carp::croak "$src: $!";

   if (-e $cache) {
      my $ref = eval { load_ref $cache };

      if ($ref->{version} == 1
          && $ref->{size} == $size
          && $ref->{mtime} == $mtime
          && eval { $load->($ref->{data}); 1 }) {
         return;
      }
   }

   my $ref = {
      version => 1,
      size    => $size,
      mtime   => $mtime,
      data    => $create->(),
   };

   $load->($ref->{data});

   save_ref $ref, $cache;
}

=item set_libdir $path

Sets the library directory to the given path
(default: $ENV{CROSSFIRE_LIBDIR}).

You have to (re-)load the archetypes and tilecache manually after steting
the library path.

=cut

sub set_libdir($) {
   $LIB = $_[0];
}

=item load_archetypes

(Re-)Load archetypes into %ARCH.

=cut

sub load_archetypes() {
   cache_file "$LIB/archetypes", "$VARDIR/archetypes.pst", sub {
      *ARCH = $_[0];
   }, sub {
      read_arch "$LIB/archetypes"
   };
}

=item load_tilecache

(Re-)Load %TILE and %FACE.

=cut

sub load_tilecache() {
   require Gtk2;

   cache_file "$LIB/crossfire.0", "$VARDIR/tilecache.pst", sub {
      $TILE = new_from_file Gtk2::Gdk::Pixbuf "$VARDIR/tilecache.png"
         or die "$VARDIR/tilecache.png: $!";
      *FACE = $_[0];
   }, sub {
      my $tile = read_pak "$LIB/crossfire.0";

      my %cache;

      my $idx = 0;

      for my $name (sort keys %$tile) {
         my $pb = new Gtk2::Gdk::PixbufLoader;
         $pb->write ($tile->{$name});
         $pb->close;
         my $pb = $pb->get_pixbuf;

         my $tile = $cache{$name} = {
            pb  => $pb,
            idx => $idx,
            w   => int $pb->get_width  / TILESIZE,
            h   => int $pb->get_height / TILESIZE,
         };
                  

         $idx += $tile->{w} * $tile->{h};
      }

      my $pb = new Gtk2::Gdk::Pixbuf "rgb", 1, 8, 64 * TILESIZE, TILESIZE * int +($idx + 63) / 64;

      while (my ($name, $tile) = each %cache) {
         my $tpb = delete $tile->{pb};
         my $ofs = $tile->{idx};

         for my $x (0 .. $tile->{w} - 1) {
            for my $y (0 .. $tile->{h} - 1) {
               my $idx = $ofs + $x + $y * $tile->{w};
               $tpb->copy_area ($x * TILESIZE, $y * TILESIZE, TILESIZE, TILESIZE,
                                $pb, ($idx % 64) * TILESIZE, TILESIZE * int $idx / 64);
            }
         }
      }

      $pb->save ("$VARDIR/tilecache.png", "png", compression => 1);

      \%cache
   };
}

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

 Robin Redeker <elmex@ta-sa.org>
 http://www.ta-sa.org/

=cut

1
