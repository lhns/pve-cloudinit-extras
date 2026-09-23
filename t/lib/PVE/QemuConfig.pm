package PVE::QemuConfig;

# Test double: which VMs exist on this node, and a lock that records its use.

use strict;
use warnings;

our %EXISTS;
our $LOCKED = 0;

sub assert_config_exists_on_node {
    my ($vmid, $node) = @_;
    die "unable to find configuration file for VM $vmid on node 'test'\n" if !$EXISTS{$vmid};
}

sub lock_config {
    my ($class, $vmid, $code, @param) = @_;
    local $LOCKED = $vmid;
    return $code->(@param);
}

1;
