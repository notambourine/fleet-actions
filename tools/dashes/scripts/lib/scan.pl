use strict;
use warnings;
use IPC::Open2;
use Errno qw(ENOENT);

my $mode = shift @ARGV;
my $target = shift @ARGV;
my @git = ('git', '-C', $ENV{DASH_ROOT});
my $dash = qr/$ENV{DASH_BYTES}/;
my $marker = qr/$ENV{DASH_MARKER_BYTES}/;
my %reported;
my $status = 0;
my ($regular, $text_file) = (1, undef);

sub read_all {
	my ($handle) = @_;
	my $data = '';
	while (1) {
		my $n = read($handle, my $chunk, 65536);
		die "read failed: $!\n" unless defined $n;
		last unless $n;
		$data .= $chunk;
	}
	return $data;
}

sub escape_data {
	my ($text) = @_;
	$text =~ s/%/%25/g;
	$text =~ s/\r/%0D/g;
	$text =~ s/\n/%0A/g;
	return $text;
}

sub report {
	my ($file, $line, $text) = @_;
	my $kind = $text =~ $marker ? 'marker' : $text =~ $dash ? 'dash' : return;
	if ($mode eq 'diff') {
		return unless $regular;
		unless (defined $text_file) {
			my $ref = $target eq ':index' ? '' : $target;
			open my $blob, '-|', @git, 'cat-file', 'blob', "$ref:$file" or die "cat-file: $!\n";
			$text_file = index(read_all($blob), "\0") < 0;
			close $blob or die "cat-file failed\n";
		}
		return unless $text_file;
	}
	my $title = $kind eq 'marker' ? 'Opt-out marker' : 'Unicode dash';
	unless ($reported{$kind}++) {
		print STDERR $kind eq 'marker'
			? "The dash-o" . "k marker no longer suppresses anything and is banned itself.\n"
			: $mode eq 'diff' ? "Unicode dashes on added lines.\n" : "Unicode dashes in this tree.\n";
		print STDERR "Fix the line, or hold the path out with the exclude input.\n\n";
	}
	chomp $text;
	my $path = escape_data($file);
	$text = escape_data($text);
	if ($ENV{DASH_STAGED}) {
		print STDERR "$path:$line:$text\n";
	} else {
		$path =~ s/:/%3A/g;
		$path =~ s/,/%2C/g;
		print STDERR "::error file=$path,line=$line,title=${title}::$text\n";
	}
	$status = 1;
}

sub unquote_path {
	my ($path) = @_;
	if ($path =~ s/^"(.*)"$/$1/s) {
		my %escapes = ('a' => "\a", 'b' => "\b", 't' => "\t", 'n' => "\n",
			'v' => "\013", 'f' => "\f", 'r' => "\r", '"' => '"', '\\' => '\\');
		$path =~ s/\\([0-7]{3}|[abtnvfr"\\])/exists $escapes{$1} ? $escapes{$1} : chr(oct($1))/ge;
	}
	$path =~ s{^b/}{} or die "missing destination prefix\n";
	return $path;
}

if ($mode eq 'diff') {
	my ($file, $line, $old_left, $new_left) = ('', 0, 0, 0);
	while (<STDIN>) {
		if ($old_left || $new_left) {
			if (/^\+/ && $new_left) {
				report($file, $line++, substr($_, 1));
				$new_left--;
			} elsif (/^-/ && $old_left) {
				$old_left--;
			} elsif (/^ / && $old_left && $new_left) {
				$old_left--;
				$new_left--;
				$line++;
			} elsif (!/^\\ No newline/) {
				die "invalid diff hunk\n";
			}
			next;
		}
		if (/^diff --git /) {
			($regular, $text_file) = (1, undef);
		} elsif (/^(?:new file mode |new mode |index \S+ )(\d+)$/) {
			$regular = $1 =~ /^100/;
		} elsif (/^\+\+\+ (.+?)\t?\n$/) {
			$file = $1 eq '/dev/null' ? '' : unquote_path($1);
		} elsif (/^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
			($old_left, $line, $new_left) = ($1 // 1, $2, $3 // 1);
		}
	}
	die "incomplete diff hunk\n" if $old_left || $new_left;
} elsif ($mode eq 'zero' || $mode eq 'count') {
	my ($reader, $writer, $pid);
	if ($target ne ':worktree') {
		$pid = open2($reader, $writer, @git, 'cat-file', '--batch');
	}
	my $count = 0;
	my %counts;
	RECORD: while (1) {
		my ($record, $file);
		{
			local $/ = "\0";
			$record = <STDIN>;
			last RECORD unless defined $record;
			if ($record eq "\0" && $mode eq 'count') {
				print "$count ";
				$count = 0;
				next RECORD;
			}
			$file = <STDIN>;
			die "incomplete tree record\n" unless defined $file;
			chomp($record, $file);
		}
		my ($permissions, $oid) = $record =~ /^:\d+ (\d+) [a-f0-9]+ ([a-f0-9]+) A$/;
		die "invalid or unmerged tree record\n" unless defined $oid;
		next unless $permissions =~ /^100/;
		if ($mode eq 'count' && exists $counts{$oid}) {
			$count += $counts{$oid};
			next;
		}
		my $data;
		if ($target eq ':worktree') {
			my $path = "$ENV{DASH_ROOT}/$file";
			next if -l $path;
			open my $input, '<', $path or do {
				next if $! == ENOENT;
				die "cannot read $path: $!\n";
			};
			$data = read_all($input);
			close $input or die "close failed: $!\n";
		} else {
			print {$writer} "$oid\n" or die "cat-file write failed: $!\n";
			my $header = <$reader>;
			die "invalid cat-file header\n" unless defined $header && $header =~ /^$oid blob (\d+)\n$/;
			my $remaining = $1 + 1;
			$data = '';
			while ($remaining) {
				my $n = read($reader, my $chunk, $remaining > 65536 ? 65536 : $remaining);
				die "incomplete blob\n" unless $n;
				$data .= $chunk;
				$remaining -= $n;
			}
			chop($data) eq "\n" or die "invalid blob terminator\n";
		}
		if ($mode eq 'count') {
			# Unchanged blobs are shared by both trees and need only one scan.
			$counts{$oid} = index($data, "\0") >= 0 ? 0 : (() = $data =~ /$dash/g);
			$count += $counts{$oid};
		} else {
			next if index($data, "\0") >= 0 || ($data !~ /$dash/ && $data !~ /$marker/);
			open my $lines, '<', \$data or die "open scalar: $!\n";
			my $line = 0;
			while (<$lines>) {
				$count += () = /$dash/g;
				report($file, ++$line, $_);
			}
		}
	}
	if (defined $pid) {
		close $writer or die "cat-file input failed\n";
		close $reader or die "cat-file output failed\n";
		waitpid($pid, 0);
		die "cat-file failed\n" if $?;
	}
	print "$count\n";
} else {
	die "unknown scan mode\n";
}

exit $status;
