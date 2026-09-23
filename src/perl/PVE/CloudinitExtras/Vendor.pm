package PVE::CloudinitExtras::Vendor;

# STUB. Pure generator/parser for cix-<vmid>-vendor.yaml; no I/O, unit-testable. See PLAN.md §2.

use strict;
use warnings;

use JSON;
use MIME::Base64 qw(encode_base64);

our $MANAGED_HEADER = 'X-Managed-By: pve-cloudinit-extras/1';
our $MAX_LINES = 200;
our $MAX_LINE_BYTES = 4096;
our $MAX_FILE_BYTES = 1024 * 1024 - 4096; # qemu-server reads snippets with a 1 MiB cap

# From https://docs.cloud-init.io/en/latest/reference/merging.html: append our runcmd to one
# from an included cloud-config instead of replacing it.
our $MERGE_HOW = [
    { name => 'list', settings => ['append'] },
    { name => 'dict', settings => ['no_replace', 'recurse_list'] },
];

# Text from the GUI -> arrayref of commands. Dies on C0/DEL control chars, invalid UTF-8, limits.
sub parse_commands {
    my ($text) = @_;
    die "not implemented\n";
}

# $include: undef | { url => $url } | { snippet => $volid, content => $bytes }
# Returns undef when no managed file is needed (neither set, or snippet only).
# Otherwise a multipart/mixed document with $MANAGED_HEADER in the top headers and base64 parts:
#   text/x-include-url | text/plain + X-PVE-Source, then text/cloud-config LAST:
#   "#cloud-config\n" . JSON->new->canonical->encode({ merge_how => $MERGE_HOW, runcmd => $commands })
# JSON is a YAML subset, so user text can only ever be string values. Enforces $MAX_FILE_BYTES.
sub render {
    my ($commands, $include) = @_;
    die "not implemented\n";
}

# Inverse of render for GET: { commands => [...], include => { url | snippet } }. Dies unless managed.
sub parse {
    my ($bytes) = @_;
    die "not implemented\n";
}

sub is_managed {
    my ($bytes) = @_;
    my ($head) = split /\r?\n\r?\n/, $bytes // '', 2;
    return defined($head) && $head =~ /^\Q$MANAGED_HEADER\E\r?$/m;
}

1;
