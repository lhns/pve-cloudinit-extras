package PVE::API2::CloudinitExtras;

# /nodes/{node}/cloudinit-extras: reads and writes the one generated vendor snippet per VM,
# <storage>:snippets/cix-<vmid>-vendor.yaml. It never changes VM or storage config (the GUI sets
# cicustom through the stock API), never touches a file it did not create, and never fetches
# the include URL (the guest does).

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::QemuConfig;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;
use PVE::Tools;

use PVE::CloudinitExtras::Vendor;

use base qw(PVE::RESTHandler);

our $VERSION = '@VERSION@';

my $READ_LIMIT = 1024 * 1024;

# Resolve the fixed target file. Everything in the path except the storage's own base path
# derives from the integer vmid, so there is nothing to traverse.
sub target {
    my ($cfg, $storage, $vmid, $node) = @_;

    my $scfg = PVE::Storage::storage_config($cfg, $storage);
    die "storage '$storage' does not have content type 'snippets'\n"
        if !$scfg->{content} || !$scfg->{content}->{snippets};
    PVE::Storage::storage_check_enabled($cfg, $storage, $node);

    my $name = PVE::CloudinitExtras::Vendor::file_name($vmid);
    my $volid = "$storage:snippets/$name";
    my ($vtype) = eval { PVE::Storage::parse_volname($cfg, $volid) };
    die "storage '$storage' cannot hold snippets\n" if !$vtype || $vtype ne 'snippets';

    PVE::Storage::activate_storage($cfg, $storage);
    my $path = PVE::Storage::path($cfg, $volid);
    die "storage '$storage' is not file based\n"
        if !defined($path) || $path !~ m{^/} || $path !~ m{/\Q$name\E\z};

    return ($volid, $path);
}

# undef if absent; dies if the path is anything but a regular file we created.
sub read_managed {
    my ($path) = @_;
    die "refusing to use $path: it is a symlink\n" if -l $path;
    return undef if !-e $path;
    die "refusing to use $path: not a regular file\n" if !-f $path;
    my $data = PVE::Tools::file_get_contents($path, $READ_LIMIT);
    die "refusing to overwrite $path: it was not created by pve-cloudinit-extras\n"
        if !PVE::CloudinitExtras::Vendor::is_managed($data);
    return $data;
}

sub read_snippet {
    my ($cfg, $volid) = @_;
    my ($vtype) = PVE::Storage::parse_volname($cfg, $volid);
    die "$volid is not a snippet\n" if $vtype ne 'snippets';
    my $path = PVE::Storage::path($cfg, $volid);
    return PVE::Tools::file_get_contents($path, $READ_LIMIT);
}

sub check_write_perms {
    my ($rpcenv, $authuser, $vmid, $storage) = @_;
    $rpcenv->check_vm_perm($authuser, $vmid, undef, ['VM.Config.Cloudinit']);
    $rpcenv->check($authuser, "/storage/$storage", ['Datastore.AllocateTemplate']);
}

my $vmid_node = {
    node => get_standard_option('pve-node'),
    vmid => get_standard_option('pve-vmid'),
    storage => get_standard_option('pve-storage-id', {
        description => "Storage holding the generated snippet.",
    }),
};

my $cmd_param = sub {
    my ($what) = @_;
    return {
        type => 'string',
        optional => 1,
        maxLength => 1024 * 1024,
        description => "cloud-init '$what' commands, one per line.",
    };
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Feature probe.",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => {
        type => 'object',
        properties => { version => { type => 'string' } },
    },
    code => sub {
        return { version => $VERSION };
    },
});

__PACKAGE__->register_method({
    name => 'get_vendor',
    path => 'vendor/{vmid}',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    description => "Read the generated vendor snippet of a VM.",
    permissions => {
        description => "VM.Audit on /vms/{vmid}.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {%$vmid_node},
    },
    returns => {
        type => 'object',
        properties => {
            volid => { type => 'string' },
            exists => { type => 'boolean' },
            bootcmd => { type => 'string' },
            runcmd => { type => 'string' },
            'include-url' => { type => 'string', optional => 1 },
            'include-snippet' => { type => 'string', optional => 1 },
        },
    },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my ($vmid, $storage) = $param->@{qw(vmid storage)};

        $rpcenv->check_vm_perm($authuser, $vmid, undef, ['VM.Audit']);
        PVE::QemuConfig::assert_config_exists_on_node($vmid);

        my $cfg = PVE::Storage::config();
        my ($volid, $path) = target($cfg, $storage, $vmid, $param->{node});
        my $data = read_managed($path);
        my $res = { volid => $volid, exists => defined($data) ? 1 : 0, bootcmd => '', runcmd => '' };
        return $res if !defined($data);

        my $d = PVE::CloudinitExtras::Vendor::parse($data);
        $res->{$_} = join("\n", $d->{$_}->@*) for @PVE::CloudinitExtras::Vendor::COMMAND_KEYS;
        $res->{'include-url'} = $d->{include}->{url} if $d->{include} && $d->{include}->{url};
        $res->{'include-snippet'} = $d->{include}->{snippet}
            if $d->{include} && $d->{include}->{snippet};
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'set_vendor',
    path => 'vendor/{vmid}',
    method => 'PUT',
    proxyto => 'node',
    protected => 1,
    description => "Write (or remove) the generated vendor snippet of a VM. Returns the value"
        . " for 'cicustom vendor=' ('' = none); the VM config itself is not changed.",
    permissions => {
        description => "VM.Config.Cloudinit on /vms/{vmid} and Datastore.AllocateTemplate on"
            . " /storage/{storage}; Datastore.Audit on the snippet's storage when a snippet"
            . " include is combined with commands (its content is copied).",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            %$vmid_node,
            bootcmd => $cmd_param->('bootcmd'),
            runcmd => $cmd_param->('runcmd'),
            'include-url' => {
                type => 'string',
                optional => 1,
                maxLength => 2048,
                description => "http(s) URL the guest includes at boot.",
            },
            'include-snippet' => {
                type => 'string',
                format => 'pve-volume-id',
                optional => 1,
                description => "Snippet volume to include.",
            },
        },
    },
    returns => {
        type => 'object',
        properties => { vendor => { type => 'string' } },
    },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my ($vmid, $storage) = $param->@{qw(vmid storage)};

        check_write_perms($rpcenv, $authuser, $vmid, $storage);

        raise_param_exc({ 'include-url' => "mutually exclusive with include-snippet" })
            if defined($param->{'include-url'}) && defined($param->{'include-snippet'});

        my $d = {};
        for my $k (@PVE::CloudinitExtras::Vendor::COMMAND_KEYS) {
            $d->{$k} = eval { PVE::CloudinitExtras::Vendor::parse_commands($param->{$k}) };
            raise_param_exc({ $k => $@ }) if $@;
        }
        my $has_cmds = grep { $d->{$_}->@* } @PVE::CloudinitExtras::Vendor::COMMAND_KEYS;

        if (defined(my $url = $param->{'include-url'})) {
            eval { PVE::CloudinitExtras::Vendor::validate_url($url) };
            raise_param_exc({ 'include-url' => $@ }) if $@;
            $d->{include} = { url => $url };
        }

        my $cfg = PVE::Storage::config();
        if (defined(my $snip = $param->{'include-snippet'})) {
            eval { PVE::CloudinitExtras::Vendor::validate_volid($snip) };
            raise_param_exc({ 'include-snippet' => $@ }) if $@;
            my ($vtype) = PVE::Storage::parse_volname($cfg, $snip);
            raise_param_exc({ 'include-snippet' => "not a snippet" }) if $vtype ne 'snippets';
            $d->{include} = { snippet => $snip };
            if ($has_cmds) {
                my ($sid) = PVE::Storage::parse_volume_id($snip);
                $rpcenv->check($authuser, "/storage/$sid", ['Datastore.Audit']);
                my $content = read_snippet($cfg, $snip);
                raise_param_exc({ 'include-snippet' => "cannot include a generated vendor"
                    . " snippet; clear Include or pick the original file" })
                    if PVE::CloudinitExtras::Vendor::is_managed($content);
                $d->{include}->{content} = $content;
            }
        }

        return PVE::QemuConfig->lock_config($vmid, sub {
            PVE::QemuConfig::assert_config_exists_on_node($vmid);
            my ($volid, $path) = target($cfg, $storage, $vmid, $param->{node});
            my $old = read_managed($path);

            my $doc = PVE::CloudinitExtras::Vendor::render($d);
            if (defined($doc)) {
                PVE::Tools::file_set_contents($path, $doc) if !defined($old) || $old ne $doc;
                return { vendor => $volid };
            }
            unlink($path) or die "unable to remove $path: $!\n" if defined($old);
            return { vendor => $d->{include} ? $d->{include}->{snippet} : '' };
        });
    },
});

1;
