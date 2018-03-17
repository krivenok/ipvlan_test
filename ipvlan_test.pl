#!/usr/bin/perl

use strict;
use warnings;
use Carp;

###############################################################################

sub create_ns
{
    my $name = shift;
    defined $name or return;
    length $name  or return;
    return system "ip netns add $name";
}

###############################################################################

sub delete_ns
{
    my $name = shift;
    defined $name or return;
    length $name  or return;
    return system "ip netns del $name";
}

###############################################################################

sub get_ns_prefix
{
    my $ns      = shift;
    my $ns_part = q{};
    (defined $ns and length $ns) and $ns_part = "ip netns exec $ns ";
    return $ns_part;
}

###############################################################################

sub change_mtu
{
    my $dev = shift;
    my $mtu = shift;
    my $ns  = shift;

    return system get_ns_prefix($ns) . "ip link set mtu  $mtu dev $dev 2>/dev/null";
}

###############################################################################

sub get_mtu
{
    my $dev = shift;
    my $ns  = shift;
    my $cmd = get_ns_prefix($ns) . "ip link show $dev | head -n1";
    my $out = `$cmd`;
    chomp $out;
    if ($out =~ /mtu\s(\d+)\s/xms)
      {
        return $1;
      }
    croak "cannot determine MTU for $dev";
}

###############################################################################

sub create_ipvlan
{
    my $base_device = shift;
    my $name        = shift;
    my $mode        = shift;
    my $flag        = shift;
    my $mtu         = shift;
    my $ns          = shift;

    my $mtu_part = q{};
    defined $mtu and $mtu_part = "mtu $mtu";
    system("ip link add $mtu_part link $base_device $name type ipvlan mode $mode $flag 2>/dev/null") == 0 or return 1;
    defined $ns                                                                                           or return;
    length $ns                                                                                            or return;
    return system "ip link set dev $name netns $ns";
}

###############################################################################

sub delete_ipvlan
{
    my $name = shift;
    my $ns   = shift;
    return system get_ns_prefix($ns) . "ip link del $name";
}

###############################################################################

my $base_device = $ARGV[0];
length ($base_device) || do {
  print "sudo ipvlan_test.pl <BASE_INTERFACE_NAME>\n";
  exit 1;
};

my $base_mtu    = get_mtu($base_device);
my $small_mtu   = $base_mtu - 1;
my $big_mtu     = $base_mtu + 1;

my $ipvlan_name = 'ipvl';
my $ns_name     = 'ipvl_ns';

my @namespaces  = (q{}, $ns_name);
my @modes = qw(l2 l3 l3s);
my @flags = qw(bridge private vepa);


create_ns($ns_name) and croak 'create_ns';
foreach my $ns (@namespaces)
  {
    my $pretty_ns = $ns;
    length $ns or $pretty_ns = 'default';
    foreach my $mode (@modes)
      {
        foreach my $flag (@flags)
          {
            # First test the case where we pass MTU at creation time
            create_ipvlan($base_device, $ipvlan_name, $mode, $flag, $big_mtu, $ns) or croak 'create_ipvlan: expected to fail';
            print "[$mode/$flag ns=$pretty_ns]: too big initial MTU: OK\n";
            create_ipvlan($base_device, $ipvlan_name, $mode, $flag, $small_mtu, $ns) and croak 'create_ipvlan';
            my $cur_ipvlan_mtu = get_mtu($ipvlan_name, $ns);
            $cur_ipvlan_mtu eq $small_mtu or croak "Initial: ipvlan MTU mismatch ($cur_ipvlan_mtu vs $small_mtu)";
            print "[$mode/$flag ns=$pretty_ns]: valid initial MTU: OK\n";
            delete_ipvlan($ipvlan_name, $ns) and croak 'delete_ipvlan';

            # Then test the case where we change parent MTU and ipvlan MTU after creation
            create_ipvlan($base_device, $ipvlan_name, $mode, $flag, undef, $ns) and croak 'create_ipvlan';

            change_mtu($base_device, $small_mtu) and croak 'change_mtu';
            $cur_ipvlan_mtu = get_mtu($ipvlan_name, $ns);
            my $cur_base_mtu = get_mtu($base_device);
            $cur_ipvlan_mtu eq $small_mtu or croak "Base MTU decrease: ipvlan MTU mismatch ($cur_ipvlan_mtu vs $small_mtu)";
            $cur_base_mtu eq $small_mtu   or croak "Base MTU decrease: base MTU mismatch ($cur_base_mtu vs $small_mtu)";
            print "[$mode/$flag ns=$pretty_ns]: base device MTU decrease: OK\n";

            change_mtu($base_device, $base_mtu) and croak 'change_mtu';
            $cur_ipvlan_mtu = get_mtu($ipvlan_name, $ns);
            $cur_base_mtu = get_mtu($base_device);
            $cur_ipvlan_mtu eq $small_mtu or croak "Base MTU increase: ipvlan MTU mismatch ($cur_ipvlan_mtu vs $small_mtu)";
            $cur_base_mtu eq $base_mtu    or croak "Base MTU increase: base MTU mismatch ($cur_base_mtu vs $small_mtu)";
            print "[$mode/$flag ns=$pretty_ns]: base device MTU increase: OK\n";

            change_mtu($ipvlan_name, $small_mtu, $ns) and croak 'change_mtu';
            $cur_ipvlan_mtu = get_mtu($ipvlan_name, $ns);
            $cur_ipvlan_mtu eq $small_mtu or croak "ipvlan MTU decrease: ipvlan MTU mismatch ($cur_ipvlan_mtu vs $small_mtu)";
            print "[$mode/$flag ns=$pretty_ns]: ipvlan device MTU decrease: OK\n";

            change_mtu($ipvlan_name, $base_mtu, $ns) and croak 'change_mtu';
            $cur_ipvlan_mtu = get_mtu($ipvlan_name, $ns);
            $cur_ipvlan_mtu eq $base_mtu or croak "ipvlan MTU increase: ipvlan MTU mismatch ($cur_ipvlan_mtu vs $base_mtu)";
            print "[$mode/$flag ns=$pretty_ns]: ipvlan device MTU increase (valid): OK\n";

            change_mtu($ipvlan_name, $big_mtu, $ns) or croak 'change_mtu: expected to fail';
            print "[$mode/$flag ns=$pretty_ns]: ipvlan device MTU increase (too big): OK\n";

            delete_ipvlan($ipvlan_name, $ns) and croak 'delete_ipvlan';
          }
      }
  }
delete_ns($ns_name) and croak 'delete_ns';
