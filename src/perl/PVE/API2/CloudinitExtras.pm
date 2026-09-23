package PVE::API2::CloudinitExtras;

# STUB. See PLAN.md §6. Writes only snippets/cix-<vmid>-vendor.yaml; never changes VM config,
# never fetches the include URL (the guest does).

use strict;
use warnings;

use PVE::CloudinitExtras::Vendor;

use base qw(PVE::RESTHandler);

# All methods: proxyto => 'node', protected => 1.
# Common checks: vmid exists on this node; storage enabled, content 'snippets', path-based;
# path = PVE::Storage::path($cfg, "$storage:snippets/cix-$vmid-vendor.yaml") (vmid is an integer).
#
# GET    /                          -> { version }                    feature probe
# GET    /vendor/{vmid}   storage   -> { volid, commands[], include } VM.Audit; no inlined content returned
# PUT    /vendor/{vmid}   storage, commands?, include-url? | include-snippet?
#   perms: VM.Config.Cloudinit on /vms/{vmid} AND Datastore.AllocateSpace on /storage/{storage};
#          plus Datastore.Audit on the source storage when include-snippet gets inlined.
#   include-url =~ m{^https?://[\x21-\x7e]{1,2040}$}; include-snippet must be vtype 'snippets'.
#   Refuse to overwrite a file that is not is_managed(); write atomically (file_set_contents).
#   neither -> delete managed file, vendor ''; snippet only -> delete managed file, vendor = snippet volid.
#   -> { vendor => <volid or ''> }, which the GUI sets via the stock PUT /config.
# DELETE /vendor/{vmid}   storage   same perms as PUT; only if is_managed().

1;
