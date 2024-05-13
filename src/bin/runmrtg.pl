#!/usr/bin/env perl

my $xsize = 400;
my $ysize = 100;

use strict;

if ( $ARGV[1] eq '' )
{
	syntax();
}

if ( !-x "$ARGV[0]" )
{
	print STDERR "ERROR: $ARGV[0] file not found or wrong permissions (execute needed)\n";
	syntax();
}

if ( !-r "$ARGV[1]" )
{
	print STDERR "ERROR $ARGV[1] file not found or wrong permission (read needed)\n";
	syntax();
}

my $path = '';

open(CONFIG,"$ARGV[1]");
while(<CONFIG>)
{
	chop;
	if ( /^PATH( |	)+(.*)$/ )
	{
		$path = $2;
	}
}
close(CONFIG);

if ( !$path )
{
	print STDERR "ERROR: cannot find 'PATH' directive in $ARGV[1]\n";
	exit 1;
}
elsif ( !-d "$path/mrtg" )
{
	print STDERR "ERROR: $path/mrtg doesnt exist or is not a directory. please create it.\n";
	exit 1;
}

if ( !-w "$path/etc" )
{
	print STDERR "ERROR: cannot create new file in $path/etc please check the permissions.\n";
	exit 1;
}

open(MRTG,">$path/etc/mrtg.conf");
open(HTML,">$path/mrtg/index.html");

print HTML <<EOF;
<html>
  <head>
    <meta content="width=device-width,initial-scale=1" name="viewport">
    <title>GenEthic bot graphics</title>
  </head>
  <body bgcolor=#F0ECEB>
  <font face=Verdana>
  <h2>GenEthic</h2><br><br>
<b>LOCAL USERS</b><br>
<a href=local_users.html><img src=local_users-day.png border=0></a><br><br>
<b>GLOBAL USERS</b><br>
<a href=global_users.html><img src=global_users-day.png border=0></a><br><br>
<b>UNKNOWN USERS</b><br>
<a href=unknown_users.html><img src=unknown_users-day.png border=0></a><br><br>
<b>CHANNELS</b><br>
<a href=channel.html><img src=channel-day.png border=0></a><br><br>
<b>USERS CONNECTING/DISCONNECTING</b><br>
<a href=users_diff.html><img src=users_diff-day.png border=0></a><br><br>
<b>CPU</b><br>
<a href=cpu.html><img src=cpu-day.png border=0></a><br><br>
EOF

print MRTG <<EOF;
# This is an auto generated config file. any change in this file will be overwritten!
# CREATED BY: $path/bin/runmrtg.pl

WorkDir: $path/mrtg

PageTop[^]: <font face=Arial>
PageFoot[\$]: </font>
BodyTag[_]: <body bgcolor=#F0ECEB>

Target[cpu]: `cat $path/mrtg/cpu.dat`
Title[cpu]: CPU
PageTop[cpu]: <h2>CPU</h2>
MaxBytes[cpu]: 100
AbsMax[cpu]: 100
WithPeak[cpu]: wmy
XSize[cpu]: $xsize
YSize[cpu]: $ysize
Options[cpu]: growright, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[cpu]: CPU
ShortLegend[cpu]: cpu

Target[local_users]: `cat $path/mrtg/local_users.dat`
Title[local_users]: LOCAL USERS
PageTop[local_users]: <h2>LOCAL USERS</h2>
MaxBytes[local_users]: 16384
AbsMax[local_users]: 100000
WithPeak[local_users]: wmy
XSize[local_users]: $xsize
YSize[local_users]: $ysize
Options[local_users]: growright, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[local_users]: LOCAL USERS
ShortLegend[local_users]: users

Target[global_users]: `cat $path/mrtg/global_users.dat`
Title[global_users]: GLOBAL USERS
PageTop[global_users]: <h2>GLOBAL USERS</h2>
MaxBytes[global_users]: 200000
AbsMax[global_users]: 1000000
WithPeak[global_users]: wmy
XSize[global_users]: $xsize
YSize[global_users]: $ysize
Options[global_users]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[global_users]: GLOBAL USERS
ShortLegend[global_users]: users

Target[unknown_users]: `cat $path/mrtg/unknown_users.dat`
Title[unknown_users]: UNKNOWN USERS
PageTop[unknown_users]: <h2>UNKNOWN USERS</h2>
MaxBytes[unknown_users]: 150
AbsMax[unknown_users]: 3000
WithPeak[unknown_users]: wmy
XSize[unknown_users]: $xsize
YSize[unknown_users]: $ysize
Options[unknown_users]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[unknown_users]: UNKNOWN USERS
ShortLegend[unknown_users]: users

Target[channel]: `cat $path/mrtg/channel.dat`
Title[channel]: CHANNELS
PageTop[channel]: <h2>CHANNELS</h2>
MaxBytes[channel]: 50000
AbsMax[channel]: 200000
WithPeak[channel]: wmy
XSize[channel]: $xsize
YSize[channel]: $ysize
Options[channel]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[channel]: CHANNELS
ShortLegend[channel]: channels

Target[users_diff]: `cat $path/mrtg/users_diff.dat`
Title[users_diff]: USERS CONNECTING/DISCONNECTING
PageTop[users_diff]: <h2>USERS CONNECTING/DISCONNECTING</h2>
MaxBytes[users_diff]: 500
AbsMax[users_diff]: 10000
WithPeak[users_diff]: wmy
XSize[users_diff]: $xsize
YSize[users_diff]: $ysize
Options[users_diff]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer
YLegend[users_diff]: USERS MOVE
ShortLegend[users_diff]: users

EOF

my %data;

open(LOG,"$path/var/genethic.log");
while(<LOG>)
{
	chop;
	my ($name,$value)=split(/:/);

	$data{$name} = $value;

	if ( $name =~ /^RPING_(.*)$/ )
	{
		my $hub = $1;
		print HTML <<EOF;
<b>RPING $hub</b><br>
<a href=rping_$hub.html><img src=rping_$hub\-day.png border=0></a><br><br>
EOF

		print MRTG <<EOF;
Target[rping_$hub]: `cat $path/mrtg/rping_$hub.dat`
Title[rping_$hub]: RPING $hub
PageTop[rping_$hub]: <h2>RPING $hub</h2>
MaxBytes[rping_$hub]: 1000
AbsMax[rping_$hub]: 1000000
WithPeak[rping_$hub]: wmy
XSize[rping_$hub]: $xsize
YSize[rping_$hub]: $ysize
Options[rping_$hub]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[rping_$hub]: RPING
ShortLegend[rping_$hub]: ms

EOF

	}
	elsif ( $name =~ /^SENDQ_(.*)$/ )
	{
		my $hub = $1;
		print HTML <<EOF;
<b>SENDQ $hub</b><br>
<a href=sendq_$hub.html><img src=sendq_$hub\-day.png border=0></a><br><br>
EOF

		print MRTG <<EOF;
Target[sendq_$hub]: `cat $path/mrtg/sendq_$hub.dat`
Title[sendq_$hub]: SENDQ $hub
PageTop[sendq_$hub]: <h2>SENDQ $hub</h2>
MaxBytes[sendq_$hub]: 1000
AbsMax[sendq_$hub]: 1000000
WithPeak[sendq_$hub]: wmy
XSize[sendq_$hub]: $xsize
YSize[sendq_$hub]: $ysize
Options[sendq_$hub]: growright, noinfo, nopercent, gauge, absolute, unknaszero, withzeroes, nobanner, nolegend, integer, noo
YLegend[sendq_$hub]: SENDQ
ShortLegend[sendq_$hub]: bytes

EOF

	}
	elsif ( $name =~ /^IF_(.*)_BYTES_I$/ )
	{
		my $ifname = $1;
		print HTML <<EOF;
<b>TRAFFIC $ifname</b><br>
<a href=traffic_$ifname.html><img src=traffic_$ifname\-day.png border=0></a><br><br>
<b>PACKETS $ifname</b><br>
<a href=packets_$ifname.html><img src=packets_$ifname\-day.png border=0></a><br><br>
EOF

		print MRTG <<EOF;
Target[traffic_$ifname]: `cat $path/mrtg/traffic_$ifname.dat`
Title[traffic_$ifname]: TRAFFIC $ifname
PageTop[traffic_$ifname]: <h2>TRAFFIC $ifname</h2>
MaxBytes[traffic_$ifname]: 1310720
AbsMax[traffic_$ifname]: 13107200
WithPeak[traffic_$ifname]: wmy
XSize[traffic_$ifname]: $xsize
YSize[traffic_$ifname]: $ysize
Options[traffic_$ifname]: growright, noinfo, nopercent, unknaszero, withzeroes, nobanner, nolegend, bits
YLegend[traffic_$ifname]: TRAFFIC $ifname

Target[packets_$ifname]: `cat $path/mrtg/packets_$ifname.dat`
Title[packets_$ifname]: PACKETS $ifname
PageTop[packets_$ifname]: <h2>PACKETS $ifname</h2>
MaxBytes[packets_$ifname]: 100000
AbsMax[packets_$ifname]: 1000000
WithPeak[packets_$ifname]: wmy
XSize[packets_$ifname]: $xsize
YSize[packets_$ifname]: $ysize
Options[packets_$ifname]: growright, noinfo, nopercent, unknaszero, withzeroes, nobanner, nolegend
YLegend[packets_$ifname]: PACKETS $ifname
ShortLegend[packets_$ifname]: p/s

EOF

	}

}
close(MRTG);

print HTML "</font>\n</html>\n";
close(HTML);

my $name;
foreach $name ( keys %data )
{
	my $filename = $name;
	$filename =~ tr/[A-Z]/[a-z]/;

	my $i = 0;
	my $o = 0;

	if ( $name =~ /^IF_(.*)_BYTES_(I|O)$/ )
	{
		my $ifname = $1;

		$i = $data{"IF_$ifname\_BYTES_I"};
		$o = $data{"IF_$ifname\_BYTES_O"};

		$filename = "traffic_$ifname";
	}
	elsif ( $name =~ /^IF_(.*)_PACKETS_(I|O)$/ )
	{
		my $ifname = $1;

		$i = $data{"IF_$ifname\_PACKETS_I"};
		$o = $data{"IF_$ifname\_PACKETS_O"};

		$filename = "packets_$ifname";
	}
	elsif ( $name =~ /^USERS_(MORE|LESS)$/ )
	{
		$i = $data{USERS_MORE};
		$o = $data{USERS_LESS};

		$filename = "users_diff";
	}
	else
	{
		$i = $data{$name};
		$o = $data{$name};
	}

	open(DAT,">$path/mrtg/$filename.dat");
	print DAT "$i\n$o\n0\n0\n";
	close(DAT);
}

open(MRTG,"$ARGV[0] $path/etc/mrtg.conf 2>&1 |");
while(<MRTG>)
{
	if ( /Use of uninitialized value/ )
	{
		# ignore
	}
	else
	{
		print "MRTG: $_";
	}
}
close(MRTG);



sub syntax
{
	print STDERR "syntax : $0 /path/to/mrtg /path/to/genethic/configfile.conf\n";
	print STDERR "example: $0 /usr/local/bin/mrtg /home/genethic/etc/genethic.conf\n";
	exit 1;
}
