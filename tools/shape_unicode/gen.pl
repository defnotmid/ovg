#!/usr/bin/perl
# Generates shape/unicode_data.odin, the Unicode character data ovg/shape
# reads, from the Unicode Character Database that ships with Perl
# (Unicode::UCD, Unicode::Normalize) and the syllabic categories in
# HarfBuzz's source (its generated tables: Unicode's Indic categories with
# its own and the Universal Shaping Engine's overrides).
#
#   perl tools/shape_unicode/gen.pl HARFBUZZ/src > shape/unicode_data.odin
#
# with HARFBUZZ the source of the HarfBuzz release shape/ is matched with
# (14.6.0).
#
# Per code point: general category, canonical combining class, script,
# joining type, Indic category and position, USE category, as an index
# into a table of the distinct combinations (two-stage: a block table,
# then the blocks, deduplicated). Then the bidi mirroring pairs, the
# canonical decompositions (first level, one or two code points) and the
# primary compositions.
use strict;
use warnings;
use Unicode::UCD qw(prop_invmap prop_values prop_value_aliases);
use Unicode::Normalize ();

my $MAX = 0x110000;
my $hb = shift @ARGV or die "usage: gen.pl HARFBUZZ/src\n";

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

# A ragel machine's exported category numbers.
sub machine_exports {
	my ($name) = @_;
	my %e;
	my $text = slurp("$hb/hb-ot-shaper-$name-machine.rl");
	while ($text =~ /^\s*export\s+(\w+)\s*=\s*(\d+)\s*;/mg) {
		$e{$1} = $2;
	}
	return \%e;
}

# A C array's values: numbers, or names `symbols` gives values.
sub c_array {
	my ($text, $name, $symbols) = @_;
	$text =~ /\b\Q$name\E\s*\[(\d*)\]\s*=\s*\{(.*?)\};/s or die "$name not found";
	my ($size, $body) = ($1, $2);
	$body =~ s{/\*.*?\*/}{}gs;
	my @v;
	for my $token (grep { /\S/ } split /,/, $body) {
		$token =~ s/^\s+|\s+$//g;
		if ($token =~ /^(\d+)u?$/) {
			push @v, $1;
		} else {
			defined $symbols && defined $symbols->{$token} or die "$name: unknown value $token";
			push @v, $symbols->{$token};
		}
	}
	@v == $size or die "$name: " . scalar(@v) . " values, declared $size";
	return \@v;
}

# A packtab lookup expression as a Perl closure over its tables.
sub lookup_closure {
	my ($expr, $tables, $b4) = @_;
	$expr =~ s/\(uint8_t\)//g;
	$expr =~ s/(\d+)u\b/$1/g;
	for my $t (sort { length($b) <=> length($a) } keys %$tables) {
		$expr =~ s/\b\Q$b4\E\(\Q$t\E,/b4(\$tables->{'$t'},/g;
		$expr =~ s/\b\Q$t\E\[/\$tables->{'$t'}->[/g;
	}
	$expr =~ s/\bu\b/\$u/g;
	my $code = "sub { my (\$u) = \@_; return $expr; }";
	my $f = eval $code or die "bad lookup: $@\n$code";
	return $f;
}

sub b4 {
	my ($a, $i) = @_;
	return ($a->[$i >> 1] >> (($i & 1) << 2)) & 15;
}

my $indic_exports = machine_exports('indic');
my $khmer_exports = machine_exports('khmer');
my $myanmar_exports = machine_exports('myanmar');
my $use_exports = machine_exports('use');

# Indic positions (hb-ot-shaper-indic.hh).
my %positions;
{
	my $text = slurp("$hb/hb-ot-shaper-indic.hh");
	while ($text =~ /\b(POS_\w+)\s*=\s*(\d+)/g) {
		$positions{$1} = $2;
	}
}

# Indic categories and positions, per code point.
my @indic = (0) x $MAX;
{
	my $text = slurp("$hb/hb-ot-shaper-indic-table.cc");
	my %ot;
	while ($text =~ /^#define\s+(OT_\w+)\s+([IKM])_Cat\((\w+)\)/mg) {
		my $e = $2 eq 'I' ? $indic_exports : $2 eq 'K' ? $khmer_exports : $myanmar_exports;
		defined $e->{$3} or die "$1: no export $3";
		$ot{$1} = $e->{$3};
	}
	# Myanmar's categories that equal Khmer's are asserted, not defined.
	while ($text =~ /static_assert \((OT_\w+) == M_Cat\((\w+)\)/g) {
		$ot{$1} == $myanmar_exports->{$2} or die "$1 differs";
	}
	my (%cat, %pos);
	while ($text =~ /^#define\s+_OT_(\w+)\s+(OT_\w+)/mg) {
		defined $ot{$2} or die "$2 undefined";
		$cat{$1} = $ot{$2};
	}
	while ($text =~ /^#define\s+_POS_(\w+)\s+(POS_\w+)/mg) {
		defined $positions{$2} or die "$2 undefined";
		$pos{$1} = $positions{$2};
	}
	$text =~ /_hb_indic_values\[\d+\]\s*=\s*\{(.*?)\};/s or die "no indic values";
	my $body = $1;
	my @values;
	while ($body =~ /_\((\w+),(\w+)\)/g) {
		defined $cat{$1} && defined $pos{$2} or die "value $1,$2";
		push @values, $cat{$1} | ($pos{$2} << 8);
	}
	my %tables;
	while ($text =~ /static const uint(?:8|16)_t (_hb_indic_u(?:8|16))\[/g) {
		$tables{$1} = c_array($text, $1);
	}
	$text =~ /_hb_indic_get_categories_index \(unsigned u\)\s*\{.*?return (.*?);\s*\}/s or die "no indic lookup";
	my $f = lookup_closure($1, \%tables, '_hb_indic_b4');
	for my $cp (0 .. $MAX - 1) {
		$indic[$cp] = $values[$f->($cp)];
	}
}

# USE categories, per code point (the table built for speed, the first).
my @use = (0) x $MAX;
{
	my $text = slurp("$hb/hb-ot-shaper-use-table.hh");
	$text =~ s/#else.*//s;
	my %tables;
	while ($text =~ /static const uint(?:8|16)_t (hb_use_u(?:8|16))\[/g) {
		$tables{$1} = c_array($text, $1, $use_exports);
	}
	$text =~ /hb_use_get_category \(unsigned u\)\s*\{.*?return (.*?);\s*\}/s or die "no use lookup";
	my $expr = $1;
	$expr =~ s/\bO\b/$use_exports->{O}/g;
	my $f = lookup_closure($expr, \%tables, 'hb_use_b4');
	for my $cp (0 .. $MAX - 1) {
		$use[$cp] = $f->($cp);
	}
}

# A property's value for every code point (inversion map expanded).
sub expand {
	my ($prop) = @_;
	my ($list, $map, $format, $default) = prop_invmap($prop);
	die "$prop: no map" unless $list;
	my @v = ($default) x $MAX;
	for my $i (0 .. $#$list) {
		my $lo = $list->[$i];
		my $hi = $i < $#$list ? $list->[$i + 1] : $MAX;
		last if $lo >= $MAX;
		$hi = $MAX if $hi > $MAX;
		for my $cp ($lo .. $hi - 1) {
			$v[$cp] = $map->[$i];
		}
	}
	return \@v;
}

my @GC = qw(Cc Cf Cn Co Cs Ll Lm Lo Lt Lu Mc Me Mn Nd Nl No Pc Pd Pe Pf Pi Po Ps Sc Sk Sm So Zl Zp Zs);
my %gc_index = map { $GC[$_] => $_ } 0 .. $#GC;

my @JT = qw(U L R D C T Alaph Dalath_Rish);
my %jt_index = map { $JT[$_] => $_ } 0 .. $#JT;

# Scripts: Unknown, Common and Inherited first, then the rest by name.
my @scripts = sort grep { $_ ne 'Unknown' && $_ ne 'Common' && $_ ne 'Inherited' } map { (prop_value_aliases('sc', $_))[1] } prop_values('sc');
unshift @scripts, 'Unknown', 'Common', 'Inherited';
my %sc_index = map { $scripts[$_] => $_ } 0 .. $#scripts;
die "too many scripts" if @scripts > 256;
my %sc_tag;
for my $s (@scripts) {
	my ($short) = prop_value_aliases('sc', $s);
	$sc_tag{$s} = $short;
}

my $gc = expand('gc');
my $ccc = expand('ccc');
my $sc = expand('sc');
my $jt = expand('jt');
my $jg = expand('jg');

# Records: the distinct (gc, ccc, script, joining, Indic, USE) combinations.
my %record_index;
my @records;
my @cp_record = (0) x $MAX;
for my $cp (0 .. $MAX - 1) {
	my $j = $jt_index{$jt->[$cp]};
	die "jt $jt->[$cp]" unless defined $j;
	if ($jg->[$cp] eq 'Alaph') {
		$j = $jt_index{Alaph};
	} elsif ($jg->[$cp] eq 'Dalath_Rish') {
		$j = $jt_index{Dalath_Rish};
	}
	my $g = $gc_index{$gc->[$cp]};
	die "gc $gc->[$cp]" unless defined $g;
	my $s = $sc_index{$sc->[$cp]};
	die "sc $sc->[$cp]" unless defined $s;
	my $key = join(',', $g, $ccc->[$cp], $s, $j, $indic[$cp], $use[$cp]);
	my $r = $record_index{$key};
	if (!defined $r) {
		$r = scalar @records;
		$record_index{$key} = $r;
		push @records, [$g, $ccc->[$cp], $s, $j, $indic[$cp] & 0xFF, $indic[$cp] >> 8, $use[$cp]];
	}
	$cp_record[$cp] = $r;
}
die "records exceed u16" if @records > 65535;

# Two-stage table: the smallest total for block sizes 2^4 .. 2^9.
my ($best_shift, $best_size, $best_blocks, $best_stage1);
for my $shift (4 .. 9) {
	my $size = 1 << $shift;
	my %block_at;
	my @blocks;
	my @stage1;
	for (my $cp = 0; $cp < $MAX; $cp += $size) {
		my $key = join(',', @cp_record[$cp .. $cp + $size - 1]);
		my $at = $block_at{$key};
		if (!defined $at) {
			$at = scalar(@blocks) * $size;
			$block_at{$key} = $at;
			push @blocks, [@cp_record[$cp .. $cp + $size - 1]];
		}
		push @stage1, $at;
	}
	my $total = 2 * @stage1 + 2 * @blocks * $size;
	if (!defined $best_size || $total < $best_size) {
		($best_shift, $best_size, $best_blocks, $best_stage1) = ($shift, $total, \@blocks, \@stage1);
	}
}
die "stage 1 offsets exceed u16" if @$best_blocks * (1 << $best_shift) > 65536;

# Bidi mirroring pairs.
my $bmg = expand('bmg');
my @mirrors;
for my $cp (0 .. $MAX - 1) {
	push @mirrors, [$cp, $bmg->[$cp] + 0] if $bmg->[$cp] ne '';
}

# Canonical decompositions, first level (Hangul is algorithmic).
my ($dm_list, $dm_map) = prop_invmap('dm');
my $dt = expand('dt');
my @decomps;
for my $i (0 .. $#$dm_list) {
	my $lo = $dm_list->[$i];
	my $hi = $i < $#$dm_list ? $dm_list->[$i + 1] : $MAX;
	last if $lo >= $MAX;
	my $m = $dm_map->[$i];
	for my $cp ($lo .. $hi - 1) {
		next unless $dt->[$cp] eq 'Canonical';
		next if $cp >= 0xAC00 && $cp <= 0xD7A3;
		my @to;
		if (ref $m) {
			@to = @$m;
		} elsif ($m =~ /^\d+$/ && $m != 0) {
			@to = ($m + $cp - $lo);
		} else {
			next;
		}
		die sprintf("decomposition of %X has %d code points", $cp, scalar @to) if @to > 2;
		push @decomps, [$cp, $to[0], $to[1] // 0];
	}
}
@decomps = sort { $a->[0] <=> $b->[0] } @decomps;

# Primary compositions: two-code-point canonical decompositions that are not
# excluded from composition.
my $comp_ex = expand('Comp_Ex');
my @comps;
for my $d (@decomps) {
	my ($cp, $a, $b) = @$d;
	next if $b == 0 || $comp_ex->[$cp] eq 'Y';
	push @comps, [$a, $b, $cp];
}
@comps = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @comps;

# ---- output -----------------------------------------------------------------------

sub rows {
	my ($per_line, @v) = @_;
	my $out = '';
	for (my $i = 0; $i < @v; $i += $per_line) {
		my $end = $i + $per_line - 1;
		$end = $#v if $end > $#v;
		$out .= "\t" . join(', ', @v[$i .. $end]) . ",\n";
	}
	return $out;
}

my $version = Unicode::UCD::UnicodeVersion();
print "// Generated by tools/shape_unicode/gen.pl from the Unicode $version character\n";
print "// database (Perl's; LICENSES/Unicode-3.0.txt) and HarfBuzz's syllabic\n";
print "// categories (LICENSES/HarfBuzz-MIT.txt). Do not edit.\n";
print "package shape\n\n";
print "UNICODE_VERSION :: \"$version\"\n\n";

print "General_Category :: enum u8 {\n";
print "\t$_,\n" for @GC;
print "}\n\n";

print "// Arabic joining types (Alaph and Dalath_Rish are Syriac's joining groups).\n";
print "Joining :: enum u8 {\n";
print "\t$_,\n" for @JT;
print "}\n\n";

print "Script :: enum u8 {\n";
print "\t$_,\n" for @scripts;
print "}\n\n";

print "// Each script's ISO 15924 tag.\n";
print "\@(rodata)\nSCRIPT_TAGS := [Script]string {\n";
for my $s (@scripts) {
	print "\t.$s = \"$sc_tag{$s}\",\n";
}
print "}\n\n";

print "Char_Props :: struct {\n\tgc:             General_Category,\n\tccc:            u8,\n\tscript:         Script,\n\tjoining:        Joining,\n\t// HarfBuzz's syllabic categories (INDIC_*, USE_*) and Indic position\n\t// (POS_*).\n\tindic:          u8,\n\tindic_position: u8,\n\tuse:            u8,\n}\n\n";
sub constants {
	my ($prefix, $comment, $e) = @_;
	print "// $comment\n";
	for my $name (sort { $e->{$a} <=> $e->{$b} || $a cmp $b } keys %$e) {
		print "${prefix}_$name :: $e->{$name}\n";
	}
	print "\n";
}
constants('INDIC', "Indic syllabic categories (HarfBuzz's Indic machine).", $indic_exports);
my %km = (%$khmer_exports, %$myanmar_exports);
for my $k (keys %km) {
	delete $km{$k} if defined $indic_exports->{$k} && $indic_exports->{$k} == $km{$k};
}
constants('INDIC', "Khmer's and Myanmar's further categories (sharing the Indic numbering).", \%km);
constants('USE', "Universal Shaping Engine categories.", $use_exports);
my %pos = map { (s/^POS_//r) => $positions{$_} } keys %positions;
constants('POS', "Positions in an Indic syllable, left to right.", \%pos);

my $size = 1 << $best_shift;
print "\@(private)\nPROPS_SHIFT :: $best_shift\n\n";
print "// Where each block of 1 << PROPS_SHIFT code points starts in PROPS_BLOCKS.\n";
print "\@(private, rodata)\nPROPS_STAGE1 := [" . scalar(@$best_stage1) . "]u16 {\n" . rows(16, @$best_stage1) . "}\n\n";
my @flat = map { @$_ } @$best_blocks;
print "// Each code point's index in PROPS_RECORDS.\n";
print "\@(private, rodata)\nPROPS_BLOCKS := [" . scalar(@flat) . "]u16 {\n" . rows(24, @flat) . "}\n\n";
print "\@(private, rodata)\nPROPS_RECORDS := [" . scalar(@records) . "]Char_Props {\n";
for my $r (@records) {
	my ($g, $c, $s, $j, $ic, $ip, $u) = @$r;
	print "\t{.$GC[$g], $c, .$scripts[$s], .$JT[$j], $ic, $ip, $u},\n";
}
print "}\n\n";

print "// Bidi mirroring glyphs: code point, its mirror; sorted.\n";
print "\@(private, rodata)\nMIRRORS := [" . scalar(@mirrors) . "][2]u32 {\n" . rows(6, map { sprintf("{0x%04X, 0x%04X}", @$_) } @mirrors) . "}\n\n";

print "// Canonical decompositions, one level: code point, then one or two code\n";
print "// points (0 for none); sorted.\n";
print "\@(private, rodata)\nDECOMPOSITIONS := [" . scalar(@decomps) . "][3]u32 {\n" . rows(4, map { sprintf("{0x%04X, 0x%04X, 0x%04X}", @$_) } @decomps) . "}\n\n";

print "// Primary compositions: the pair, then the composite; sorted by pair.\n";
print "\@(private, rodata)\nCOMPOSITIONS := [" . scalar(@comps) . "][3]u32 {\n" . rows(4, map { sprintf("{0x%04X, 0x%04X, 0x%04X}", @$_) } @comps) . "}\n";

printf STDERR "records %d, shift %d, stage1 %d, blocks %d (%d bytes), mirrors %d, decompositions %d, compositions %d\n",
	scalar(@records), $best_shift, scalar(@$best_stage1), scalar(@$best_blocks), $best_size, scalar(@mirrors), scalar(@decomps), scalar(@comps);
