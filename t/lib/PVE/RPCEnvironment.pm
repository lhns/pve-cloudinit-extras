package PVE::RPCEnvironment;

# Test double: permissions come from a table, checks die like the real ones.

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc);

our $USER = 'root@pam';
our %PERMS; # "$path" => { privilege => 1 }
our @CHECKS; # log of [path, privs]

my $env = bless {}, __PACKAGE__;

sub get { return $env }
sub get_user { return $USER }

sub check {
    my ($self, $user, $path, $privs, $noerr) = @_;
    push @CHECKS, [$path, [@$privs]];
    for my $p (@$privs) {
        next if $PERMS{$path} && $PERMS{$path}->{$p};
        return undef if $noerr;
        raise_perm_exc("$path, $p");
    }
    return 1;
}

sub check_vm_perm {
    my ($self, $user, $vmid, $pool, $privs, $any, $noerr) = @_;
    return $self->check($user, "/vms/$vmid", $privs, $noerr);
}

1;
