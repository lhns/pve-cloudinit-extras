package PVE::API2::CloudinitExtras;

# STUB. See PLAN.md §6. Writes only snippets/cix-<vmid>-include.yaml; never touches VM config.

use strict;
use warnings;

use base qw(PVE::RESTHandler);

# TODO register_method:
#   GET    /             -> { version }                      (feature probe)
#   GET    /include/{vmid}?storage=  -> { url }              VM.Audit
#   PUT    /include/{vmid} {storage, url} -> volid           VM.Config.Cloudinit + Datastore.AllocateSpace
#   DELETE /include/{vmid}?storage=                          same perms; only files with our header
# All: proxyto => 'node', protected => 1; storage must have content 'snippets' and be path-based;
# url =~ m{^https?://[\x21-\x7e]{1,2040}$}; path via PVE::Storage::path; atomic file_set_contents.

1;
