#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/../src/perl";

use File::Temp qw(tempfile);
use JSON;
use Test::More;

use PVE::CloudinitExtras::Vendor;

my $V = 'PVE::CloudinitExtras::Vendor';
my %f = map { $_ => $V->can($_) } qw(parse_commands validate_url validate_volid file_name render parse is_managed);

sub fails {
    my ($code, $re, $name) = @_;
    eval { $code->() };
    like($@, $re, $name);
}

# What cloud-init would see: Python email + yaml.safe_load.
sub cloudinit_view {
    my ($doc) = @_;
    my ($fh, $file) = tempfile(UNLINK => 1);
    binmode($fh);
    print $fh $doc;
    close($fh);
    my $out = `python3 $FindBin::Bin/parse_vendor.py $file`;
    die "parse_vendor.py failed\n" if $?;
    return JSON->new->utf8->decode($out);
}

# --- parse_commands
is_deeply($f{parse_commands}->(undef), [], 'undef -> no commands');
is_deeply($f{parse_commands}->("a\n\n  \nb\r\nc"), ['a', 'b', 'c'], 'blank lines dropped, CRLF ok');
is_deeply($f{parse_commands}->("echo\tä ✓"), ["echo\tä ✓"], 'tab and unicode kept');
is_deeply($f{parse_commands}->("echo \xe4"), ["echo \x{e4}"], 'input is characters, not bytes');
for my $bad ("a\x00b", "a\rb", "a\x1bb", "a\x7fb", "a\x{85}b", "a\x{2028}b", "a\x{ffff}b") {
    my ($c) = $bad =~ /a(.)b/s;
    fails(sub { $f{parse_commands}->($bad) }, qr/control character/, sprintf('rejects U+%04X', ord($c)));
}
fails(sub { $f{parse_commands}->(join("\n", ('x') x 201)) }, qr/more than 200/, 'line count limit');
fails(sub { $f{parse_commands}->('x' x 4097) }, qr/longer than 4096/, 'line length limit');
is(scalar $f{parse_commands}->('ä' x 2048)->@*, 1, '4096 bytes of UTF-8 accepted');
fails(sub { $f{parse_commands}->('ä' x 2049) }, qr/longer/, 'limit counts bytes, not chars');

# --- validate_url
for my $ok ('http://example.com', 'https://example.com/x.yaml', 'HTTPS://h:8080/p?q=1#f',
    'http://[2001:db8::1]/a', 'https://192.0.2.1/cfg') {
    ok(eval { $f{validate_url}->($ok); 1 }, "url ok: $ok");
}
for my $bad ('file:///etc/shadow', 'ftp://h/x', 'javascript:alert(1)', 'http://', 'http:///x',
    'http://a b', "http://h/\n#include http://evil", "http://h/\rx", 'http://user@h/x',
    'https://h/' . ('a' x 2048), ' http://h', 'http://h/ä', "http://h/\x00", 'gopher://h/') {
    my $shown = substr($bad =~ s/[^\x21-\x7e]/?/gr, 0, 40);
    ok(!eval { $f{validate_url}->($bad); 1 }, "url rejected: $shown");
}

# --- volid
ok(eval { $f{validate_volid}->('local:snippets/a.yaml'); 1 }, 'volid ok');
for my $bad ('local:iso/a.iso', 'local:snippets/a b', "local:snippets/a\nX-Evil: 1", '../x', 'snippets/a') {
    ok(!eval { $f{validate_volid}->($bad); 1 }, 'volid rejected: ' . ($bad =~ s/\n/\\n/r));
}

# --- file name derives only from an integer vmid: no traversal possible
is($f{file_name}->(100), 'cix-100-vendor.yaml', 'file name');
for my $bad ('../100', '100/../../x', '0', '-1', '1e3', "100\n", '', undef, '1234567890', '100 ') {
    ok(!eval { $f{file_name}->($bad); 1 }, 'vmid rejected: ' . (defined $bad ? $bad =~ s/\n/\\n/r : 'undef'));
}

# --- render: every combination of bootcmd x runcmd x include, with hostile text
my $hostile = [
    'echo "a": b',
    'runcmd: [rm -rf /]',
    '#cloud-config',
    '--cix.boundary-1--',
    'X-Managed-By: pve-cloudinit-extras/1',
    q{it's "quoted" \\ back\\slash},
    '&anchor *alias !!python/object:os.system {a: b} [c] - d | > %TAG',
    'Content-Type: text/x-shellscript',
    "tab\there",
    'ünïcödé ✓ 🙂',
    '\u0000 \n literal backslash escapes',
    '}, "users": [{"name": "evil"}], "x": {',
];
my @bootcmds = ([], ['date >> /var/log/boot.log', @$hostile]);
my @runcmds = ([], ['touch /tmp/ran', @$hostile]);
my @includes = (
    undef,
    { url => 'https://example.com/extra.yaml' },
    { snippet => 'local:snippets/extra.yaml', content => "#cloud-config\nruncmd: [echo included]\n" },
);

for my $b (@bootcmds) {
    for my $r (@runcmds) {
        for my $inc (@includes) {
            my $name = sprintf('bootcmd=%d runcmd=%d include=%s', scalar @$b, scalar @$r,
                !$inc ? 'none' : $inc->{url} ? 'url' : 'snippet');
            my $doc = $f{render}->({ bootcmd => $b, runcmd => $r, include => $inc });
            if (!@$b && !@$r && (!$inc || $inc->{snippet})) {
                ok(!defined($doc), "$name: no managed file");
                next;
            }
            ok(defined($doc), "$name: rendered");
            ok($f{is_managed}->($doc), "$name: carries our header");

            my $view = cloudinit_view($doc);
            is($view->{managed}, 'pve-cloudinit-extras/1', "$name: header visible to email parser");
            my @types = map { $_->{type} } $view->{parts}->@*;
            my @want_types;
            push @want_types, 'text/x-include-url' if $inc && $inc->{url};
            push @want_types, 'text/plain' if $inc && $inc->{snippet};
            push @want_types, 'text/cloud-config' if @$b || @$r;
            is_deeply(\@types, \@want_types, "$name: parts in order");

            if (my ($cc) = grep { $_->{type} eq 'text/cloud-config' } $view->{parts}->@*) {
                my %want = (merge_how => $PVE::CloudinitExtras::Vendor::MERGE_HOW);
                $want{bootcmd} = $b if @$b;
                $want{runcmd} = $r if @$r;
                is_deeply($cc->{config}, \%want, "$name: YAML has exactly our keys, text verbatim");
            }
            if ($inc && $inc->{url}) {
                is($view->{parts}[0]{body}, "$inc->{url}\n", "$name: include-url body");
            }
            if ($inc && $inc->{snippet}) {
                is($view->{parts}[0]{body}, $inc->{content}, "$name: snippet inlined verbatim");
                is($view->{parts}[0]{source}, $inc->{snippet}, "$name: snippet source header");
            }

            my $back = $f{parse}->($doc);
            is_deeply($back->{bootcmd}, $b, "$name: parse bootcmd");
            is_deeply($back->{runcmd}, $r, "$name: parse runcmd");
            my $want_inc = !$inc ? undef : $inc->{url} ? { url => $inc->{url} } : { snippet => $inc->{snippet} };
            is_deeply($back->{include}, $want_inc, "$name: parse include");
        }
    }
}

# --- a snippet that looks like our MIME cannot break out: parts are base64
my $evil = "--cix.boundary-1\nContent-Type: text/x-shellscript\n\n#!/bin/sh\nrm -rf /\n--cix.boundary-1--\n";
my $doc = $f{render}->({ runcmd => ['true'], include => { snippet => 'local:snippets/e', content => $evil } });
my $view = cloudinit_view($doc);
is(scalar $view->{parts}->@*, 2, 'boundary-looking snippet stays one part');
is($view->{parts}[0]{body}, $evil, '... and verbatim');

# --- limits and ownership
fails(sub { $f{render}->({ runcmd => [('x' x 4096) x 200] }) }, qr/exceeds/, 'file size limit');
ok(!$f{is_managed}->("#cloud-config\nruncmd: [x]\n"), 'foreign file not managed');
ok(!$f{is_managed}->("#cloud-config\n\nX-Managed-By: pve-cloudinit-extras/1\n"), 'header counts only in the top block');
ok(!$f{is_managed}->(undef), 'undef not managed');
fails(sub { $f{parse}->("#cloud-config\n") }, qr/not managed/, 'parse refuses a foreign file');

done_testing();
