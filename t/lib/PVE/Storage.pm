package PVE::Storage;

# Test double for the parts of PVE::Storage the endpoint uses. Volume parsing mirrors
# PVE::Storage::Plugin (dir plugin) so path handling is tested against the real rules.

use strict;
use warnings;

use PVE::JSONSchema;

our $CFG = { ids => {} }; # set by tests: storeid => { type, path, content => {snippets => 1}, disable }
our @ACTIVATED;

sub parse_volume_id {
    my ($volid, $noerr) = @_;
    if ($volid =~ m/^([a-z][a-z0-9\-\_\.]*[a-z0-9]):(.+)$/i) {
        return wantarray ? ($1, $2) : $1;
    }
    return undef if $noerr;
    die "unable to parse volume ID '$volid'\n";
}
PVE::JSONSchema::register_format('pve-volume-id', \&parse_volume_id);

sub config { return $CFG }

sub storage_config {
    my ($cfg, $storeid) = @_;
    return $cfg->{ids}->{$storeid} // die "storage '$storeid' does not exist\n";
}

sub storage_check_enabled {
    my ($cfg, $storeid, $node) = @_;
    die "storage '$storeid' is disabled\n" if storage_config($cfg, $storeid)->{disable};
    return 1;
}

sub activate_storage { push @ACTIVATED, $_[1] }

sub parse_volname {
    my ($cfg, $volid) = @_;
    my ($storeid, $volname) = parse_volume_id($volid);
    my $scfg = storage_config($cfg, $storeid);
    die "unable to parse volume name '$volname'\n" if $scfg->{type} ne 'dir';
    return ('snippets', $1) if $volname =~ m!^snippets/([^/]+)$!;
    return ('iso', $1) if $volname =~ m!^iso/([^/]+\.iso)$!;
    die "unable to parse directory volume name '$volname'\n";
}

sub path {
    my ($cfg, $volid) = @_;
    my ($storeid, $volname) = parse_volume_id($volid);
    my $scfg = storage_config($cfg, $storeid);
    return "rbd:pool/$volname" if $scfg->{type} ne 'dir';
    my (undef, $name) = parse_volname($cfg, $volid);
    return "$scfg->{path}/snippets/$name";
}

1;
