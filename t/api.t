#!/usr/bin/perl
# Endpoint tests: real PVE::RESTHandler/JSONSchema/Tools (libpve-common-perl), test doubles for
# storage, permissions and VM config (t/lib).
use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../src/perl";

use File::Find;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON;
use Test::More;

use PVE::API2::CloudinitExtras;
use PVE::CloudinitExtras::Vendor;
use PVE::QemuConfig;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Tools;

my $API = 'PVE::API2::CloudinitExtras';
my $root = tempdir(CLEANUP => 1);
make_path("$root/$_/snippets") for qw(snip snip2 isoonly off);
make_path("$root/outside");

$PVE::Storage::CFG = { ids => {
    snip => { type => 'dir', path => "$root/snip", content => { snippets => 1 } },
    snip2 => { type => 'dir', path => "$root/snip2", content => { snippets => 1 } },
    isoonly => { type => 'dir', path => "$root/isoonly", content => { iso => 1 } },
    off => { type => 'dir', path => "$root/off", content => { snippets => 1 }, disable => 1 },
    block => { type => 'rbd', content => { snippets => 1 } },
} };
%PVE::QemuConfig::EXISTS = (100 => 1, 101 => 1);
$PVE::RPCEnvironment::USER = 'user@pve';

my %ALL = (
    '/vms/100' => { 'VM.Config.Cloudinit' => 1, 'VM.Audit' => 1 },
    '/vms/101' => { 'VM.Config.Cloudinit' => 1, 'VM.Audit' => 1 },
    '/vms/999' => { 'VM.Config.Cloudinit' => 1, 'VM.Audit' => 1 },
    '/storage/snip' => { 'Datastore.AllocateTemplate' => 1, 'Datastore.Audit' => 1 },
    '/storage/snip2' => { 'Datastore.AllocateTemplate' => 1, 'Datastore.Audit' => 1 },
    map { ("/storage/$_" => { 'Datastore.AllocateTemplate' => 1 }) } qw(isoonly off block nope),
);
sub perms { %PVE::RPCEnvironment::PERMS = (%ALL, @_) }
perms();

my $file100 = "$root/snip/snippets/cix-100-vendor.yaml";

sub call {
    my ($name, $param) = @_;
    my $info = $API->map_method_by_name($name) or die "no method $name\n";
    return $API->handle($info, { node => 'testnode', %$param });
}

# Returns undef on success, else the error (HTTP code if it has one).
sub err_of {
    my ($name, $param) = @_;
    eval { call($name, $param) };
    my $e = $@ or return undef;
    return ref($e) && $e->{code} ? "$e->{code} " . ($e->{msg} // '') . ' ' . encode_json($e->{errors} // {}) : "$e";
}

sub put { call('set_vendor', { vmid => 100, storage => 'snip', @_ }) }
sub slurp { PVE::Tools::file_get_contents($_[0]) }
sub all_files {
    my @f;
    find({ wanted => sub { push @f, $File::Find::name if -f $_ || -l $_ }, no_chdir => 1 }, $root);
    return [sort @f];
}

# --- feature probe
is(call('index', {})->{version}, '@VERSION@', 'probe returns version (substituted at build)');

# --- permissions
perms('/vms/100' => {});
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x' }), qr/^403/, 'PUT needs VM.Config.Cloudinit');
perms('/vms/100' => { 'VM.Config.Network' => 1, 'VM.Audit' => 1 });
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x' }), qr/^403/, '... VM.Config.Network is not enough');
perms('/storage/snip' => { 'Datastore.AllocateSpace' => 1, 'Datastore.Audit' => 1 });
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x' }), qr/^403.*AllocateTemplate/,
    'PUT needs Datastore.AllocateTemplate on the target storage (AllocateSpace is not enough)');
ok(!-e $file100, 'nothing written without permission');
perms('/vms/100' => {});
like(err_of('get_vendor', { vmid => 100, storage => 'snip' }), qr/^403/, 'GET needs VM.Audit');
perms();
is(put(runcmd => 'x')->{vendor}, 'snip:snippets/cix-100-vendor.yaml', 'PUT with both permissions works');

# snippet content is copied only if the user may read that storage
PVE::Tools::file_set_contents("$root/snip2/snippets/extra.yaml", "#cloud-config\nruncmd: [echo inc]\n");
perms('/storage/snip2' => { 'Datastore.AllocateTemplate' => 1 });
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x', 'include-snippet' => 'snip2:snippets/extra.yaml' }),
    qr/^403.*Datastore.Audit/, 'inlining a snippet needs Datastore.Audit on its storage');
is(put('include-snippet' => 'snip2:snippets/extra.yaml')->{vendor}, 'snip2:snippets/extra.yaml',
    'a snippet include alone is referenced, not read, so needs no Audit');
perms();

# --- path handling: nothing user-controlled reaches the file name
my $before = all_files();
for my $case (
    [{ vmid => '../100' }, 'vmid ../100'],
    [{ vmid => '100/../../outside/x' }, 'vmid with slashes'],
    [{ vmid => '100 ' }, 'vmid with space'],
    [{ vmid => 'abc' }, 'vmid not a number'],
    [{ storage => '../outside' }, 'storage ../outside'],
    [{ storage => 'snip/../../outside' }, 'storage with slashes'],
    [{ storage => '/etc' }, 'storage absolute path'],
    [{ 'include-snippet' => 'snip:snippets/../../../outside/x' }, 'include-snippet traversal'],
    [{ 'include-snippet' => 'snip:snippets/sub/x' }, 'include-snippet subdir'],
    [{ 'include-snippet' => 'snip:iso/x.iso' }, 'include-snippet of another content type'],
    [{ 'include-snippet' => "snip:snippets/x\nX-Evil: 1" }, 'include-snippet with newline'],
    [{ 'include-snippet' => '/etc/passwd' }, 'include-snippet absolute path'],
) {
    my ($p, $name) = @$case;
    ok(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x', %$p }), "rejected: $name");
}
ok(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x', node => '../x' }), 'rejected: node name');
is_deeply(all_files(), $before, 'rejected requests created or removed no file');

like(err_of('set_vendor', { vmid => 999, storage => 'snip', runcmd => 'x' }), qr/configuration file/, 'VM must exist on this node');
like(err_of('set_vendor', { vmid => 100, storage => 'isoonly', runcmd => 'x' }), qr/snippets/, 'storage must allow snippets');
like(err_of('set_vendor', { vmid => 100, storage => 'off', runcmd => 'x' }), qr/disabled/, 'storage must be enabled');
like(err_of('set_vendor', { vmid => 100, storage => 'block', runcmd => 'x' }), qr/cannot hold snippets|not file based/,
    'storage must be file based');
like(err_of('set_vendor', { vmid => 100, storage => 'nope', runcmd => 'x' }), qr/does not exist/, 'unknown storage');

# symlink planted at the fixed name is never followed
unlink($file100);
PVE::Tools::file_set_contents("$root/outside/target", "precious\n");
symlink("$root/outside/target", $file100) or die;
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x' }), qr/symlink/, 'symlink at target refused');
like(err_of('set_vendor', { vmid => 100, storage => 'snip' }), qr/symlink/, '... also for delete');
is(slurp("$root/outside/target"), "precious\n", 'symlink target untouched');
unlink($file100);

# --- header-guarded overwrite
PVE::Tools::file_set_contents($file100, "#cloud-config\nruncmd: [admin wrote this]\n");
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x' }), qr/not created by pve-cloudinit-extras/,
    'foreign file at the fixed name is not overwritten');
like(err_of('set_vendor', { vmid => 100, storage => 'snip' }), qr/not created by/, '... nor deleted');
like(err_of('get_vendor', { vmid => 100, storage => 'snip' }), qr/not created by/, '... nor parsed');
is(slurp($file100), "#cloud-config\nruncmd: [admin wrote this]\n", 'foreign file unchanged');
unlink($file100);

put(runcmd => 'first');
put(runcmd => 'second');
is(call('get_vendor', { vmid => 100, storage => 'snip' })->{runcmd}, 'second', 'own file is overwritten');
is(put()->{vendor}, '', 'clearing everything returns empty vendor');
ok(!-e $file100, '... and deletes our file');
is(put()->{vendor}, '', 'clearing again is a no-op');

# a generated file of another VM (e.g. after a clone) is not inlined
call('set_vendor', { vmid => 101, storage => 'snip', runcmd => 'other vm' });
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => 'x', 'include-snippet' => 'snip:snippets/cix-101-vendor.yaml' }),
    qr/cannot include a generated vendor snippet/, 'refuses to inline another generated file');
is(put('include-snippet' => 'snip:snippets/cix-101-vendor.yaml')->{vendor}, 'snip:snippets/cix-101-vendor.yaml',
    '... but may reference it directly');

# --- URL validation through the API (the host never fetches it)
for my $bad ('file:///etc/passwd', 'ftp://h/x', 'http://h/a b', "http://h/\n#include http://evil", 'http://u@h/', 'x') {
    like(err_of('set_vendor', { vmid => 100, storage => 'snip', 'include-url' => $bad }), qr/include-url/,
        'bad url rejected: ' . ($bad =~ s/\n/\\n/r));
}
like(err_of('set_vendor', { vmid => 100, storage => 'snip', 'include-url' => 'http://h/', 'include-snippet' => 'snip:snippets/a' }),
    qr/mutually exclusive/, 'url and snippet are exclusive');
like(err_of('set_vendor', { vmid => 100, storage => 'snip', runcmd => "a\x1bb" }), qr/runcmd.*control/, 'runcmd control char');
like(err_of('set_vendor', { vmid => 100, storage => 'snip', bootcmd => "a\x00b" }), qr/bootcmd.*control/, 'bootcmd control char');
for my $f (qw(Vendor.pm)) {
    my $src = slurp("$FindBin::Bin/../src/perl/PVE/CloudinitExtras/$f") . slurp("$FindBin::Bin/../src/perl/PVE/API2/CloudinitExtras.pm");
    unlike($src, qr/LWP|HTTP::Tiny|IO::Socket|curl|wget|download_url/, 'no code path fetches URLs');
}

# --- all combinations of bootcmd, runcmd and include, round-tripped through GET
my $hostile = join("\n", 'echo "a": b', 'runcmd: [rm -rf /]', '--cix.boundary-1--', "it's \\ \"q\"",
    '}, "users": [{"name": "evil"}], "x": {', 'ünï ✓');
my @includes = (
    [none => {}, ''],
    [url => { 'include-url' => 'https://example.com/extra.yaml' }],
    [snippet => { 'include-snippet' => 'snip2:snippets/extra.yaml' }],
);
for my $b ('', "date >> /var/log/boots\n$hostile") {
    for my $r ('', "touch /tmp/ran\n$hostile") {
        for my $i (@includes) {
            my ($iname, $ip) = @$i;
            my $name = sprintf('bootcmd=%s runcmd=%s include=%s', $b ? 'set' : '-', $r ? 'set' : '-', $iname);
            my %p = (%$ip, ($b ? (bootcmd => $b) : ()), ($r ? (runcmd => $r) : ()));
            my $res = put(%p);
            my $managed = $b || $r || $iname eq 'url';
            if ($managed) {
                is($res->{vendor}, 'snip:snippets/cix-100-vendor.yaml', "$name: vendor = generated file");
                my $g = call('get_vendor', { vmid => 100, storage => 'snip' });
                is($g->{bootcmd}, $b, "$name: GET bootcmd");
                is($g->{runcmd}, $r, "$name: GET runcmd");
                is($g->{'include-url'}, $ip->{'include-url'}, "$name: GET include-url");
                is($g->{'include-snippet'}, $ip->{'include-snippet'}, "$name: GET include-snippet");
                my $doc = slurp($file100);
                my $keys = join(',', sort map { /^\{/ ? keys %{ decode_json($_) } : () }
                    map { MIME::Base64::decode_base64($_) =~ s/^#cloud-config\n//r }
                    ($doc =~ /text\/cloud-config.*?\n\n(.*?)\n--/sg));
                is($keys, join(',', grep { $_ } ($b ? 'bootcmd' : ''), 'merge_how', ($r ? 'runcmd' : '')),
                    "$name: cloud-config has exactly the expected keys") if $b || $r;
            } else {
                is($res->{vendor}, $ip->{'include-snippet'} // '', "$name: vendor = " . ($ip->{'include-snippet'} // 'none'));
                ok(!-e $file100, "$name: no generated file");
                ok(!call('get_vendor', { vmid => 100, storage => 'snip' })->{exists}, "$name: GET reports none");
            }
        }
    }
}

done_testing();
