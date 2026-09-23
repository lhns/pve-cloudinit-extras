package PVE::CloudinitExtras::Vendor;

# Pure generator/parser for the per-VM vendor snippet (cix-<vmid>-vendor.yaml). No I/O.
# Format and rationale: PLAN.md §2.

use strict;
use warnings;

use Encode qw(encode);
use JSON;
use MIME::Base64 qw(encode_base64 decode_base64);

our $MANAGED_HEADER = 'X-Managed-By: pve-cloudinit-extras/1';
our $BOUNDARY = 'cix.boundary-1'; # '.' and '-' never occur in base64, so no part can contain it
our $MAX_LINES = 200;
our $MAX_LINE_BYTES = 4096;
our $MAX_URL_BYTES = 2048;
our $MAX_FILE_BYTES = 1024 * 1024 - 4096; # qemu-server reads snippets with a 1 MiB cap

# https://docs.cloud-init.io/en/latest/reference/merging.html: append our lists to those of an
# included cloud-config instead of replacing them.
our $MERGE_HOW = [
    { name => 'list', settings => ['append'] },
    { name => 'dict', settings => ['no_replace', 'recurse_list'] },
];

our @COMMAND_KEYS = qw(bootcmd runcmd);

sub file_name {
    my ($vmid) = @_;
    die "invalid vmid\n" if !defined($vmid) || $vmid !~ /^[1-9][0-9]{0,8}\z/;
    return "cix-$vmid-vendor.yaml";
}

# Textarea content (a character string, as the API server decodes it) -> arrayref of commands.
# Blank lines are dropped.
# Rejects what PyYAML would not read back verbatim inside a quoted scalar: C0 except TAB,
# DEL, C1 (incl. NEL), U+2028/2029, U+FFFE/FFFF.
sub parse_commands {
    my ($text) = @_;
    return [] if !defined($text) || $text eq '';
    my @out;
    for my $line (split /\r?\n/, $text) {
        next if $line =~ /^\s*\z/;
        die "command contains a control character\n"
            if $line =~ /[\x00-\x08\x0a-\x1f\x7f-\x9f\x{2028}\x{2029}\x{fffe}\x{ffff}]/;
        die "command longer than $MAX_LINE_BYTES bytes\n"
            if length(encode('UTF-8', $line)) > $MAX_LINE_BYTES;
        push @out, $line;
        die "more than $MAX_LINES commands\n" if @out > $MAX_LINES;
    }
    return \@out;
}

sub validate_url {
    my ($url) = @_;
    die "include URL must be http(s)://host/...\n"
        if !defined($url) || $url !~ m{\Ahttps?://[^/?#\s\@]+(?:[/?#][\x21-\x7e]*)?\z}i;
    die "include URL longer than $MAX_URL_BYTES bytes\n" if length($url) > $MAX_URL_BYTES;
    return $url;
}

sub validate_volid {
    my ($volid) = @_;
    die "invalid snippet volume id\n"
        if !defined($volid) || $volid !~ m{\A[a-z][a-z0-9\-_.]*[a-z0-9]:snippets/[\x21-\x7e]+\z}i;
    return $volid;
}

sub _part {
    my ($type, $body, @headers) = @_;
    return join("\n",
        "--$BOUNDARY",
        "Content-Type: $type",
        'Content-Transfer-Encoding: base64',
        @headers,
        '',
        encode_base64($body)); # encode_base64 output ends in "\n"
}

# $d = { bootcmd => [..], runcmd => [..], include => undef | {url => $u} | {snippet => $v, content => $bytes} }
# Returns the file content (bytes), or undef when no managed file is needed: nothing set, or a
# snippet include alone (that one is referenced directly).
sub render {
    my ($d) = @_;
    my %cmds = map { $_ => ($d->{$_} // []) } @COMMAND_KEYS;
    my $has_cmds = grep { @{ $cmds{$_} } } @COMMAND_KEYS;
    my $inc = $d->{include};

    return undef if !$has_cmds && (!$inc || defined($inc->{snippet}));

    my @parts;
    if ($inc && defined($inc->{url})) {
        push @parts, _part('text/x-include-url; charset="utf-8"', validate_url($inc->{url}) . "\n");
    } elsif ($inc && defined($inc->{snippet})) {
        validate_volid($inc->{snippet});
        die "snippet content missing\n" if !defined($inc->{content});
        push @parts, _part('text/plain', $inc->{content}, "X-PVE-Source: $inc->{snippet}");
    }
    if ($has_cmds) {
        my $cfg = { merge_how => $MERGE_HOW };
        for my $k (@COMMAND_KEYS) {
            $cfg->{$k} = $cmds{$k} if @{ $cmds{$k} };
        }
        # JSON is valid YAML: user text can only ever become a string value, never a key.
        my $json = JSON->new->utf8->canonical->encode($cfg);
        push @parts, _part('text/cloud-config; charset="utf-8"', "#cloud-config\n$json\n");
    }

    my $doc = join("\n",
        $MANAGED_HEADER,
        qq{Content-Type: multipart/mixed; boundary="$BOUNDARY"},
        'MIME-Version: 1.0',
        '',
        '') . join('', @parts) . "--$BOUNDARY--\n";

    die "generated vendor data exceeds $MAX_FILE_BYTES bytes\n" if length($doc) > $MAX_FILE_BYTES;
    return $doc;
}

sub is_managed {
    my ($bytes) = @_;
    return 0 if !defined($bytes);
    my ($head) = split /\r?\n\r?\n/, $bytes, 2;
    return defined($head) && $head =~ /^\Q$MANAGED_HEADER\E\r?$/m ? 1 : 0;
}

# Inverse of render, for our own files only:
# { bootcmd => [..], runcmd => [..], include => undef | {url} | {snippet} }
sub parse {
    my ($bytes) = @_;
    die "file is not managed by pve-cloudinit-extras\n" if !is_managed($bytes);
    my (undef, $body) = split /\n\n/, $bytes, 2;
    my $res = { bootcmd => [], runcmd => [], include => undef };
    for my $part (split /^--\Q$BOUNDARY\E(?:--)?\n/m, $body // '') {
        my ($h, $b) = split /\n\n/, $part, 2;
        next if !defined($b);
        my ($type) = $h =~ /^Content-Type:\s*([^;\s]+)/mi or next;
        my $data = decode_base64($b);
        if ($type eq 'text/x-include-url') {
            my ($url) = grep { $_ ne '' && !/^#/ } split /\n/, $data;
            $res->{include} = { url => $url };
        } elsif ($type eq 'text/plain') {
            my ($src) = $h =~ /^X-PVE-Source:\s*(\S+)/mi;
            $res->{include} = { snippet => $src };
        } elsif ($type eq 'text/cloud-config') {
            $data =~ s/\A#cloud-config\n//;
            my $cfg = JSON->new->utf8->decode($data);
            $res->{$_} = $cfg->{$_} // [] for @COMMAND_KEYS;
        }
    }
    return $res;
}

1;
