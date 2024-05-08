#!/usr/local/bin/perl
#
#    =====================================================================
#    |                   SPALEWARE LICENSE (Revision 0.1)                |
#    |-------------------------------------------------------------------|
#    | This file is part of a package called "GenEthic" and is           |
#    | licensed under SPALEWARE. You may freely modify and distribute    |
#    | this package or parts of it. But you MUST keep the SPALWARE       |
#    | license in it!                                                    |
#    |                                                                   |
#    =====================================================================
#
# You might want to enable debug, which
# will send you the IRC traffic to STDOUT
#
my $debug = 0;
#
######################################################
#                                                    #
# There's nothing to change below this line.         #
#                                                    #
######################################################
#
#

use strict;
use File::Basename;
use IO::Socket;
use POSIX "setsid";
use Time::Local;
use Time::HiRes qw (sleep);
use File::Copy;
use LWP::UserAgent;

$|=1;

my $version = '1.0';

$SIG{PIPE} = "IGNORE";
$SIG{CHLD} = "IGNORE";

my %server;
my %data;
my $config;

if ( $ARGV[0] )
{
	if ( $ARGV[0] =~ /^\// ) { $config = $ARGV[0]; }
	else { $config = "$ENV{PWD}/$ARGV[0]"; }
}

my %conf = load_config($config);

if ( !%conf )
{
	exit 1;
}

logmsg("entering main loop");

if ( !$debug )
{
	daemonize();
}

$server{lastcon} = time - 61;

while(1)
{
	if ( !$server{socket} )
	{
		if ( $server{lastcon} < time - 60 )
		{
			logmsg("trying to connect");
			if ( connect_irc() )
			{
				logmsg("connected");
				if ( $conf{serverpass} )
				{
					queuemsg(1,"PASS $conf{serverpass}");
				}
				queuemsg(1,"USER $conf{ident} . . :$conf{rname}");
				$data{nick} = get_nick();
				queuemsg(1,"NICK $data{nick}");
			}
			else
			{
				logmsg("connection failed");
			}
			$server{lastcon} = time;
		}
		elsif ( !(($server{lastcon} - time + 60) % 5) )
		{
			logmsg("Retrying to connect in " . ( $server{lastcon} - time + 60 ) . " sec");
		}
	}
	else
	{
		$data{status}{report} = time + $conf{pollinterval};
		while($server{socket})
		{
			read_irc();

			foreach(@{$server{in}})
			{
				$server{lastin} = time;
				irc_loop(shift(@{$server{in}}));
			}

			if ( $data{rfs} )
			{
				timed_events();
			}

			write_irc();

			if ( time - $server{lastin} > $conf{timeout} )
			{
				logmsg("ERROR: Server timed out");
				shutdown($server{socket},2);
				undef %server;
				undef %data;
			}
		}
	}
	sleep(1);
}


sub push_notify($)
{

	if ( !$conf{pushenable} ) { return 0; }

	my $message = $_[0];
	my $url = 'https://api.pushover.net/1/messages.json';

	foreach ( @{$conf{usertoken}} )
	{
		LWP::UserAgent->new()->post(
		  "https://api.pushover.net/1/messages.json", [
		  "token" =>  $conf{pushtoken},
		  "user" =>  $_,
		  "message" => $message,
		]);
	}
}


sub queuemsg
{
	my $level = shift;
	my $msg   = shift;

	if ( $level == 1 )
	{
		push(@{$server{out1}},$msg);
	}
	elsif ( $level == 2 )
	{
		push(@{$server{out2}},$msg);
	}
	elsif ( $level == 3 )
	{
		push(@{$server{out3}},$msg);
	}
}

sub timed_events
{

	if ( time - $data{connexitclean} > 3600 )
	{
		# time to clean the connexit file
		my @CONN;
		open(CONN,"$conf{path}/var/connexit.txt");
		while(<CONN>)
		{
			if ( /^(\d+) / )
			{
				if ( $1 > time - 3600 )
				{
					push(@CONN,$_);
				}
			}
		}
		close(CONN);

		open(CONN,">$conf{path}/var/connexit.txt");
		foreach(@CONN)
		{
			print CONN $_;
		}
		close(CONN);

		$data{connexitclean} = time;
	}
	if ( time - $data{notice}{lastcheck} >= 0 && time - $data{notice}{lastprint} >= $conf{cetimethres} )
	{
		my $time;
		my $userchange = 0;
		my $usermore = 0;
		my $userless = 0;
		foreach $time ( sort keys %{$data{notice}{move}} )
		{
			if ( $time >= time - $conf{cetimethres} )
			{
				$userchange += $data{notice}{move}{$time};
				if ( $data{notice}{move}{$time} =~ /^\d/ )
				{
					$usermore += $data{notice}{move}{$time};
				}
				else
				{
					$userless -= $data{notice}{move}{$time};
				}
			}
			else
			{
				delete($data{notice}{move}{$time});
			}
		}

		if ( abs($userchange) >= $conf{ceuserthres} )
		{
			if ( $userchange =~ /^\d+$/ ) { $userchange = "+$userchange"; }
	
			queuemsg(2,"NOTICE \@$conf{channel} :WARNING Possible attack, $userchange (+$usermore/-$userless) users in $conf{cetimethres} seconds ($data{lusers}{locusers} users)");
			push_notify("USER CHANGE: +$usermore/-$userless");
			$data{notice}{lastprint} = time;
		}
		$data{notice}{lastcheck} = time;
	}
	
	if ( ( time - $data{status}{report} ) >= $conf{pollinterval} )
	{
		# its report time

		open(MAP,">$conf{path}/var/map.txt");
		foreach ( keys %{$data{statsv}} )
		{
			print MAP "$_ $data{statsv}{$_}{users}\n";
		}
		close(MAP);

		open(MRTG,">$conf{path}/var/genethic.log");

		my $trafmsg = 'TRAFFIC->';
		if ( $conf{trafficreport} )
		{
			%{$data{cpu}{new}} = cpu();

			my $tot = ( $data{cpu}{new}{used} + $data{cpu}{new}{idle} ) - ( $data{cpu}{old}{used} + $data{cpu}{old}{idle} );
			my $used = $data{cpu}{new}{used} - $data{cpu}{old}{used};
			my $time = $tot / 100;
			my $pcent = 0;
			if ( $time > 0 )
			{
				$pcent = int($used / $time);
			}

			print MRTG sprintf("CPU:%s\n",$pcent);

			%{$data{cpu}{old}} = %{$data{cpu}{new}};
			
			$data{traftime}{old} = $data{traftime}{new};
			$data{traftime}{new} = time;
			%{$data{traffic}{new}} = traffic();

			my $difftime = $data{traftime}{new} - $data{traftime}{old};

			my $ifname;
			foreach $ifname ( sort keys %{$data{traffic}{new}} )
			{
				print MRTG "IF_$ifname\_PACKETS_I:" . $data{traffic}{new}{$ifname}{ip} . "\n";
				print MRTG "IF_$ifname\_PACKETS_O:" . $data{traffic}{new}{$ifname}{op} . "\n";
				print MRTG "IF_$ifname\_BYTES_I:"   . $data{traffic}{new}{$ifname}{ib} . "\n";
				print MRTG "IF_$ifname\_BYTES_O:"   . $data{traffic}{new}{$ifname}{ob} . "\n";
				my %rate;
				foreach ( keys %{$data{traffic}{new}{$ifname}} )
				{
					if ( exists $data{traffic}{old}{$ifname} )
					{
						my $old = $data{traffic}{old}{$ifname}{$_};
						my $new = $data{traffic}{new}{$ifname}{$_};

						if ( $new < $old )
						{
							$new += 4294967296;
						}

						$rate{$_} = int ( ( $new - $old ) / $difftime );

					}

					$data{traffic}{old}{$ifname}{$_} = $data{traffic}{new}{$ifname}{$_};
				}

				if ( $data{traftime}{old} )
				{
					$rate{ib} = int ( $rate{ib} * 8 / 1024 );
					$rate{ob} = int ( $rate{ob} * 8 / 1024 );
					$trafmsg .= " $ifname $rate{ib}/$rate{ob} kbps $rate{ip}/$rate{op} pps";
				}
			}
		}

		$data{status}{report} = time - (  time % $conf{pollinterval} );

		if ( !$conf{hubmode} )
		{
#			my $servcount = $data{statsv}{$data{servername}}{users};
			my $servcount = $data{lusers}{locusers};
			my $pos = 1;
			my $all = 0;
			foreach ( keys %{$data{statsv}} )
			{
				if ( $data{statsv}{$_}{users} > 15 )
				{
					$all++;
				}

				if ( $servcount < $data{statsv}{$_}{users} )
				{
					$pos++;
				}
			}

			if ( !$data{lusers}{unknown} ) { $data{lusers}{unknown} = 0; }
			if ( !$data{notice}{more} ) { $data{notice}{more} = 0; }
			if ( !$data{notice}{less} ) { $data{notice}{less} = 0; }

			if ( $conf{reportenable} )
			{ 
				my $pcent = sprintf("%0.2f%%",$data{lusers}{locusers}/$data{lusers}{glousers}*100);

				my $moreless = "(\+$data{notice}{more}/\-$data{notice}{less})";

				my $statmsg = "$data{lusers}{locusers}($pcent)/$data{lusers}{glousers} $moreless. ";

				my $diff = 0;
				if ( exists $data{last}{channels} )
				{
					$diff = $data{lusers}{channels} - $data{last}{channels};
				}

				if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

				$statmsg .= "No $pos/$all. ";
				$statmsg .= "$data{lusers}{channels}($diff)chans, ";
				$statmsg .= "$data{lusers}{unknown} unknown";

				$data{last}{channels} = $data{lusers}{channels};

				queuemsg(2,"NOTICE \@$conf{channel} :$statmsg");
			}

			print MRTG "LOCAL_USERS:$data{lusers}{locusers}\n";
			print MRTG "GLOBAL_USERS:$data{lusers}{glousers}\n";
			print MRTG "UNKNOWN_USERS:$data{lusers}{unknown}\n";
			print MRTG "MAX_LOCAL_USERS:$data{lusers}{maxusers}\n";
			print MRTG "CHANNEL:$data{lusers}{channels}\n";
			print MRTG "POSITION:$pos\n";
			print MRTG "USERS_PERCENT:" . int($data{lusers}{locusers}/$data{lusers}{glousers}*10000) . "\n";
			print MRTG "USERS_MORE:$data{notice}{more}\n";
			print MRTG "USERS_LESS:$data{notice}{less}\n";

			$data{notice}{more} = 0;
			$data{notice}{less} = 0;
		}

		my $rpingmsg;

		foreach( keys %{$data{clines}} )
		{
			# We only want rping for unlinked C:lines. If SendQ exists, its linked.
			# In HUBMODE, we only include other hubs.
			if ( !exists $data{uplinks}{$_} && ( ( $conf{hubmode} && $data{statsv}{$_}{hub} ) || !$conf{hubmode} ) )
			{
				my $rpdiff = 0;
				my $hub = $_;
				$hub =~ s/\.$conf{networkdomain}//;

				if ( exists $data{last}{rping}{$_} )
				{
					$rpdiff = $data{clines}{$_} - $data{last}{rping}{$_};
					if ( $rpdiff =~ /^\d+$/ ) { $rpdiff ="+$rpdiff"; }
					$rpingmsg .= "$hub:$data{clines}{$_}($rpdiff) ";
				}
				else
				{
					$rpingmsg .= "$hub:$data{clines}{$_} ";
				}

				if ( $data{clines}{$_} =~ /^\d+$/ )
				{
					print MRTG "RPING_$_:$data{clines}{$_}\n";
					$data{last}{rping}{$_} = $data{clines}{$_};
				}
			}
		}

		if ( $rpingmsg && $conf{reportenable} )
		{
			$rpingmsg =~ s/\s+$//;
			queuemsg(2,"NOTICE \@$conf{channel} :RPING  -> $rpingmsg");
		}

		my $linkmsg;

		foreach( keys %{$data{uplinks}} )
		{
			my $uplink = $_;
			$uplink =~ s/\.$conf{networkdomain}//;

			$linkmsg .= "$uplink\[";

			if ( exists $data{clines}{$_} )
			{
				my $rpdiff = 0;

				if ( exists $data{last}{rping}{$_} )
				{
					$rpdiff = $data{clines}{$_} - $data{last}{rping}{$_};
					if ( $rpdiff =~ /^\d+$/ ) { $rpdiff ="+$rpdiff"; }
					$linkmsg .= "rp:$data{clines}{$_}($rpdiff)";
				}
				else
				{
					$linkmsg .= "rp:$data{clines}{$_}";
				}

				$data{last}{rping}{$_} = $data{clines}{$_};

				print MRTG "RPING_$_:$data{clines}{$_}\n";
			}

			my $sqdiff = 0;

			if ( exists $data{last}{sendq}{$_} )
			{
				$sqdiff = $data{uplinks}{$_} - $data{last}{sendq}{$_};
				if ( $sqdiff =~ /^\d+$/ ) { $sqdiff ="+$sqdiff"; }
				$linkmsg .= " sq:$data{uplinks}{$_}($sqdiff)";
			}
			else
			{
				$linkmsg .= " sq:$data{uplinks}{$_}";
			}

			if ( $data{uplinks}{$_} =~ /^\d+$/ )
			{
				$data{last}{sendq}{$_} = $data{uplinks}{$_};
				print MRTG "SENDQ_$_:$data{uplinks}{$_}\n";
			}

			my $uptime = easytime(time-$data{statsv}{$_}{linkts});
			$linkmsg .= " up:$uptime] ";
		}

		if ( $linkmsg && $conf{reportenable} )
		{
			queuemsg(2,"NOTICE \@$conf{channel} :UPLINK -> $linkmsg");
		}

		close(MRTG);

		if ( $trafmsg =~ /\d/ )
		{
			queuemsg(2,"NOTICE \@$conf{channel} :$trafmsg");
		}

		# its IMPORT_FILE time

		if ( -r "$conf{import_file}" )
		{
			my $import = 'IMPORT ->';
			open(IMPORT,"$conf{import_file}");
			while(<IMPORT>)
			{
				chop;
				my ($name,$limit,$value)=split(/\;/);

				if ( $limit =~ /any/i )
				{
					# always display
					$import .= " $name:$value";
				}
				elsif ( $limit >= 0  && $value >= $limit )
				{
					# display with threshold
					$import .= " $name:$value";
				}
			}
			close(IMPORT);

			if ( $import =~ /\d/ )
			{
				queuemsg(2,"NOTICE \@$conf{channel} :$import");
			}
		}

		# clone check time
		if ( !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
		{
			my %counter;

			foreach ( keys %{$data{who}} )
			{
				my $rname = $data{who}{$_}{rname};
				$rname =~ tr/[A-Z]/[a-z]/;
				if ( length($rname) < 3 ) { next; }

				$counter{$rname}++;
			}
			my $rname;
			foreach $rname ( keys %counter )
			{
				if ( $counter{$rname} >= $conf{rnameglinelimit} )
				{
					# exceeds gline limit

					my $ignore = 0;
					foreach ( @{$conf{rnamelist}} )
					{
						my $match = wild2reg($_);
						if ( $rname =~ /^$match$/ )
						{
							$ignore = 1;
						}
					}

					if ( !$ignore )
					{
						my $rnamewild = '';
						foreach (split(//,$rname))
						{
							if ( $_ =~ /(\w|\-|\=|\_|\;|\,|\.)/ )
							{
								$rnamewild .= $_;
							}
							else
							{
								$rnamewild .= "?";
							}
						}
						my $rnamereg  = $rnamewild;
						$rnamereg =~ s/\./\\./g;
						$rnamereg =~ s/\?/./g;

						# applying new rname on user list;

						my $newmatch = 0;
						foreach ( keys %{$data{who}} )
						{
							if ( $data{who}{$_}{rname} =~ /^$rnamereg$/i )
							{
								$newmatch++;
							}
						}

						if ( $counter{$rname} eq $newmatch )
						{
							if ( $conf{locglineaction} =~ /warn/i )
							{
								queuemsg(2,"NOTICE \@$conf{channel} :CLONE WARNING:: '$rname' -> '$rnamewild' ($newmatch users)");
							}
							elsif ( $conf{locglineaction} =~ /gline/i )
							{
								queuemsg(2,"NOTICE \@$conf{channel} :GLINE for '$rname' -> '$rnamewild' ($newmatch users)");
								queuemsg(2,"GLINE +\$R$rnamewild $conf{rnameglinetime} :Auto-Klined for $conf{rnameglinetime} seconds.");
							}
						}
						else
						{
							if ( $conf{locglineaction} =~ /gline/i )
							{
								queuemsg(2,"NOTICE \@$conf{channel} :GLINE WARNING will not set gline for '$rname' (gline on '$rnamewild') should affect $counter{$rname} users, but will affect $newmatch users. Please take a manual action!");
							}
						}
					}
				}
			}
			undef %counter;

			# Check for IP clones
			foreach ( keys %{$data{who}} )
			{
				my $cnet = $data{who}{$_}{ip};
				$cnet =~ s/\.\d+$/\.\*/;
				$counter{$cnet}++;
			}

			my $userip;
			foreach $userip ( keys %counter )
			{
				if ( $counter{$userip} >= $conf{ipglinelimit} )
				{
					my $ignore = 0;
					foreach ( @{$conf{iplist}} )
					{
						my $match = wild2reg($_);
						if ( $userip =~ /^$match$/ )
						{
							$ignore = 1;
						}
					}
					if ( !$ignore )
					{
						if ( $conf{locglineaction} =~ /warn/i )
						{
							queuemsg(2,"NOTICE \@$conf{channel} :CLONE WARNING: '$userip' ($counter{$userip} users)");
						}
						elsif ( $conf{locglineaction} =~ /gline/i )
						{
							queuemsg(2,"NOTICE \@$conf{channel} :GLINE for '$userip' ($counter{$userip} users)");
							queuemsg(2,"GLINE \!\+*\@$userip $conf{ipglinetime} :Auto-Klined for $conf{ipglinetime} seconds.");
						}
					}
				}
			}
		}
	}

	if ( ( time - $data{status}{polling} ) >= ( $conf{pollinterval} - 30 ) )
	{
		# its poll time

		$data{status}{polling} = time;

		if ( $data{status}{statsc} )
		{
			queuemsg(1,"STATS c");
			$data{status}{statsc} = 0;
		}
		else
		{
			$data{status}{statsc} = 1;
			$data{time}{statsc} = time;
		}

		if ( $data{status}{statsv} )
		{
			queuemsg(1,"STATS v");
			$data{status}{statsv} = 0;
			delete $data{statsv};
		}
		else
		{
			$data{status}{statsv} = 1;
			$data{time}{statsv} = time;
		}

		if ( $data{status}{statsl} )
		{
			queuemsg(1,"STATS l");
			$data{status}{statsl} = 0;
			delete $data{statsl};
		}
		else
		{
			$data{status}{statsl} = 1;
			$data{time}{statsl} = time;
		}

		if ( !$conf{hubmode} )
		{
			if ( $data{status}{lusers} )
			{
				queuemsg(1,"LUSERS");
				$data{status}{lusers} = 0;
			}
			else
			{
				$data{status}{lusers} = 1;
				$data{time}{lusers} = time;
			}
		}

		if ( !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
		{
			if ( $data{status}{who} )
			{
				open(WHO,">$conf{path}/var/users.tmp");
				close(WHO);
				queuemsg(1,"WHO $data{servername} x%nuhilraf");
				$data{status}{who} = 0;
				delete $data{who};
				$data{autoid} = 0;
			}
			else
			{
				$data{status}{who} = 1;
				$data{time}{who} = time;
			}
		}
	}

}

sub irc_loop
{
	my $line = shift;

	if ( $line =~ s/^:((\\|\||\`|\[|\]|\^|\{|\}|\-|\_|\w)+)\!((\~|\w|\[|\])+)\@((\w|\.|\-|\_)+) //i )
	{
		# user stuff

		my $nick = $1;
		my $user = $3;
		my $host = $5;

		if ( $line =~ /^JOIN (:|)$conf{channel}$/i )
		{
			# user joined channel

			if ( $nick =~ /^$data{nick}$/i )
			{
				# its me!
				queuemsg(1,"MODE $conf{channel} +o $data{nick}");
				queuemsg(1,"WHO $conf{channel} xc%nif");
				delete $data{oper};
			}
			else
			{
				queuemsg(2,"WHOIS $nick");
				queuemsg(2,"USERIP $nick");
				queuemsg(2,"PRIVMSG $nick :TIME");
				queuemsg(2,"NOTICE $nick :Please wait while checking your identity...");
			}
		}
		elsif ( $line =~ s/^MODE $conf{channel} //i )
		{
			# channel mode
			if ( $line =~ /^\+o $data{nick}$/i )
			{
				if ( $data{lusers}{maxusers} && !$conf{hubmode} ) {
					queuemsg(1,"MODE $conf{channel} +l $data{lusers}{maxusers}");
				}
				queuemsg(1,"MODE $conf{channel} +imnst-pr");
			}
			elsif ( $line =~ /^(\-|\+|\w)+( \d+)*$/ )
			{
				if ( $nick =~ /^$data{nick}$/i )
				{
					# nothing yet
				}
				else
				{
					if ( $data{lusers}{maxusers} && !$conf{hubmode} ) {
						queuemsg(2,"MODE $conf{channel} +l $data{lusers}{maxusers}");
					}
					queuemsg(2,"MODE $conf{channel} +imnst-pr");
				}
			}
		}
		elsif ( $line =~ s/^(PRIVMSG|NOTICE) $data{nick} ://i && $data{oper}{$nick} )
		{
			# message from oper
			my $replymode = $1;

			# is ctcp ?
			if ( $line =~ /^/ )
			{
				if ( $line =~ /^TIME (.*)$/i )
				{
					$data{offset}{$nick} = guess_tz($1);
					my $offset = easytime($data{offset}{$nick});
					if ( $offset =~ /^\d/ ) { $offset = "+$offset"; }
					queuemsg(2,"NOTICE $nick :Your offset to GMT is $offset. Timestamps in DCC will be shown in your localtime.");
				}
			}
			elsif ( $line =~ s/^help *//i )
			{
				if ( $line =~ /nick/i )
				{
					queuemsg(3,"$replymode $nick :command: NICK <nickname>");
					queuemsg(3,"$replymode $nick :note   : change the nickname of the bot.");
				}
				elsif ( $line =~ /reload/i )
				{
					queuemsg(3,"$replymode $nick :command: RELOAD <cold|warm>");
					queuemsg(3,"$replymode $nick :note   : 'warm' reload configuration on the fly.");
					queuemsg(3,"$replymode $nick :       : 'cold' reload configuration and restart.");
				}
				elsif ( $line =~ /raw/i )
				{
					queuemsg(3,"$replymode $nick :command: RAW <command>");
					queuemsg(3,"$replymode $nick :note   : sends a command directly to the server.");
					if ( !$conf{enableraw} )
					{
						queuemsg(3,"$replymode $nick :warning: THIS COMMAND IS DISABLED BY CONFIGURATION!");
					}
				}
				elsif ( $line =~ /dcc/i )
				{
					queuemsg(3,"$replymode $nick :command: DCC <ip> [port]");
					queuemsg(3,"$replymode $nick :note   : starts a DCC session. the port is optional.");
				}
				else
				{
					queuemsg(3,"$replymode $nick :command: HELP <nick|raw|dcc|reload>");
					queuemsg(3,"$replymode $nick :note   : help about commands");
				}
			}
			elsif ( $line =~ s/^reload *//i )
			{
				if ( $line =~ /warm/i )
				{
					%conf = load_config($config);
					queuemsg(3,"NOTICE \@$conf{channel} :configuration reloaded by $nick");
					queuemsg(3,"$replymode $nick :configuration reloaded.");
				}
				elsif ( $line =~ /cold/i )
				{
					queuemsg(1,"QUIT :cold reload requested by $nick (be back in about $conf{timeout} seconds).");
					%conf = load_config($config);
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help reload'");
				}
			}
			elsif ( $line =~ s/^nick *//i )
			{
				if ( $line =~ /^(\w+)$/ )
				{
					queuemsg(3,"NICK $1");
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help nick'");
				}
			}
			elsif ( $line =~ s/^dcc *//i )
			{

				my $userip = 0;
				my $userport = 0;

				if ( $line =~ /^(\d+\.\d+\.\d+\.\d+|)$/ || $line =~ /^(\d+\.\d+\.\d+\.\d+|) (\d+)$/)
				{
					foreach ( @{$conf{dccips}} )
					{
						if ( $_ eq $1 )
						{
							$userip = $_;
						}
					}

					if ( $2 ) {
						$userport = $2;
					}
				}

				if ( $conf{dccenable} eq 0 )
				{
					queuemsg(3,"$replymode $nick :DCC is disabled by configuration.");
				}
				elsif ( !$userip )
				{
					queuemsg(3,"$replymode $nick :Invalid IP. You must select either of the following IP addresses: @{$conf{dccips}}.");
				}
				elsif ( $conf{dccport} && $userport )
				{
					queuemsg(3,"$replymode $nick :You cannot specify a DCC port. It has been fixed by configuration.");
				}
				else
				{

					my ($dccsock,$dccport) = init_dcc($userip,$userport);

					if ( $dccsock && $dccport )
					{
						my $code = gencode();
						queuemsg(3,"NOTICE \@$conf{channel} :$nick requested DCC, code is $code");
						my $dccip = unpack("N",inet_aton($userip));
						queuemsg(3,"PRIVMSG $nick :DCC CHAT chat $dccip $dccport");
						dcc($dccsock,$code,$data{offset}{$nick});
					}
					else
					{
						queuemsg(3,"$replymode $nick :Failed to initialize DCC");
					}
				}
			}
			elsif ( $line =~ s/^raw *//i )
			{
				if ( $line =~ /^(.+)$/ )
				{
					if ( $conf{enableraw} )
					{
						queuemsg(3,"$1");
					}
					else
					{
						queuemsg(3,"$replymode $nick :This command is disabled (by configuration).");
					}
				}
				else
				{
					queuemsg(3,"$replymode $nick :error: missing or incorrect argument(s), try 'help raw'");
				}
			}
			else
			{
				queuemsg(3,"$replymode $nick :Unknown command '$line', try 'help'");
			}
		}
		elsif ( $line =~ /^NICK :(.*)$/ )
		{
			my $newnick = $1;
			if ( $nick =~ /^$data{nick}$/i )
			{
				$data{nick} = $newnick;
			}
			else
			{
				$data{oper}{$newnick} = $data{oper}{$nick};
				delete $data{oper}{$nick};
				$data{offset}{$newnick} = $data{offset}{$newnick};
				delete $data{offset}{$nick};
			}
		}
		elsif ( $line =~ /^PART|QUIT/ )
		{
			delete $data{oper}{$nick};
		}

	}
	elsif ( $line =~ s/^:((\w|\.|\-|\_)+) //i )
	{

		my $logline = $line;

		if ( $logline =~ s/^NOTICE \* ://i )
		{
			if ( $logline =~ /^\*\*\* Notice -- (BOUNCE or )*HACK\((\d+)\): (.*) \[(\d+)\]$/i )
			{
				# hack_type:timestamp:msg
				writemsg("hack","$2:$4:$3");
			}
			elsif ( $logline =~ /Client connecting: (.*) \((.*)\) \[(.*)\] \{(.*)\} \[(.*)\] <(.*)>$/ )
			{
				# nick:host:ip:numeric:class:rname/reason
				writemsg("connexit","CONN:$1:$2:[$3]:$6:$4:$5");
			}
			elsif ( $logline =~ /Client exiting: (.*) \((.*)\) \[(.*)\] \[(.*)\] <(.*)>$/ )
			{
				# nick:host:ip:numeric:class:rname/reason
				writemsg("connexit","EXIT:$1:$2:[$4]:$5::$3");
			}
			elsif ( $logline =~ /\*\*\* Notice -- (.*) adding (local|global) GLINE for (.*), expiring at (\d+): (.*)/i )
			{
				# gline_type:who:user@host:expire
				if ( $2 eq 'local' )
				{
					queuemsg(3,"NOTICE \@$conf{channel} :LOCGLINE for $3 set by $1 ($5)");
				}
				writemsg("gline","$2:$1:$3:$4:$5");
			}
			elsif ( $logline =~ s/^\*\*\* Notice -- //i )
			{
				writemsg("notice",$logline);
			}
		}
		# server stuff

		if ( $line =~ /^(376|422) /  )
		{
			# end of MOTD 376 or MOTD file missing 422
			queuemsg(1,"OPER $conf{operuser} $conf{operpass}");
		}
		elsif ( $line =~ /^002 $data{nick} :Your host is (.*), running version/ )
		{
			$data{servername} = $1;
			$data{servername} =~ tr/[A-Z]/[a-z]/;
		}
		elsif ( $line =~ /^381 / )
		{
			# OPER done
			queuemsg(1,"MODE $data{nick} +ids 65535");
			queuemsg(1,"JOIN :$conf{channel}");
		}
		elsif ( $line =~ /^(471|472|473|474|475) /  )
		{
			# Unable to join channel, OVERRIDE it !
			queuemsg(1,"JOIN $conf{channel} :OVERRIDE");
		}
		elsif ( $line =~ /^433 / )
		{
			# nickname already in use.
			$data{nick} = get_nick();
			queuemsg(1,"NICK $data{nick}");
		}
		elsif ( $line =~ /^313 $data{nick} (.*) :is an irc operator$/i )
		{
			$data{oper}{$1} = 1;
			queuemsg(2,"MODE $conf{channel} +o $1");
		}
		elsif ( $line =~ /^340 $data{nick} :(.*)=(.*)@((\.|\:|[a-f]|[0-9])+)$/i )
		{
				my $nick = $1;
				$nick =~ tr/\*//d;

				foreach ( @{$conf{ippermit}} )
				{
					if ( $3 =~ /^$_$/ )
					{
						queuemsg(2,"MODE $conf{channel} +o $nick");
					}
				}
		}
		elsif ( $line =~ /^251 $data{nick} :There are (\d+) users and (\d+) invisible/i )
		{
			my $total = $1 + $2;
			$data{lusers}{glousers} = $total;
		}
		elsif ( $line =~ /^253 $data{nick} (\d+) :/i )
		{
			$data{lusers}{unknown} = $1;
		}
		elsif ( $line =~ /^254 $data{nick} (\d+) :/i )
		{
			$data{lusers}{channels} = $1;
		}
		elsif ( $line =~ /^255 $data{nick} :I have (\d+) clients/i )
		{
			$data{lusers}{locusers} = $1;
		}
		elsif ( $line =~ s/^354 $data{nick} //i )
		{
			if ( $line =~ /^((\~|\w|\{|\}|\[|\]|\^|\.|\-|\|)+) (.*) ((\w|\-|\:|\_|\.)+) ((\\|\||\`|\[|\]|\{|\}|\-|\_|\w|\^)+) ((\w|\@|\<|\+|\-|\*)+) (\d+) (\w+) :(.*)$/i )
			{
				$data{autoid}++;
				my $autoid = $data{autoid};

				$data{who}{$autoid}{user}  = $1;
				$data{who}{$autoid}{ip}    = $3;
				$data{who}{$autoid}{host}  = $4;
				$data{who}{$autoid}{nick}  = $6;
				$data{who}{$autoid}{mode}  = $8;
				$data{who}{$autoid}{idle}  = $10;
				$data{who}{$autoid}{xuser} = $11;
				$data{who}{$autoid}{rname} = $12;
				open(WHO,">>$conf{path}/var/users.tmp");
				print WHO "$1	$3	$4	$6	$10	$11	$12	$8\n";
				close(WHO);
			}
			elsif ( $line =~ /^((\d|\.|\:|\w)+) ((\\|\||\`|\[|\]|\^|\{|\}|\-|\_|\w)+) ((\*|\@|\w)+)$/i )
			{
				# channel who
				my $ip = $1;
				my $opernick = $3;
				my $modes = $5;
				my $permitted = 0;

				foreach ( @{$conf{ippermit}} )
				{
					if ( $ip =~ /^$_$/ )
					{
						$permitted = 1;
					}
				}

				if ( $modes =~ /\*/ )
				{
					# is oper
					$data{oper}{$opernick} = 1;
				}
				elsif ( !$permitted )
				{ 
					# is not oper nor permitted
					delete $data{oper}{$opernick};
					queuemsg(2,"KICK $conf{channel} $opernick :You have no right to be in this channel!");
				}
			}
		}
		elsif ( $line =~ /^315 $data{nick} / )
		{
			# end of WHO
			if ( !$data{rfs} )
			{ 
				queuemsg(2,"NOTICE \@$conf{channel} :GenEthic-Enhanced v$conf{version}, ready.");
			}
			$data{rfs} = 1;
			if ( !$conf{hubmode} && $conf{locglineaction} !~ /disable/i )
			{
				$data{status}{who} = 1;
				copy("$conf{path}/var/users.tmp", "$conf{path}/var/users.txt");
			}
		}
		elsif ( $line =~ s/^213 $data{nick} C //i )
		{
			my ($hub, undef, undef) = split(/ /,$line);
			$hub =~ tr/[A-Z]/[a-z]/;
			if ( !exists $data{clines}{$hub} )
			{
				$data{clines}{$hub} = "n/a";
			}
		}
		elsif ( $line =~ s/^211 $data{nick} ((\w|\d|\.)+) (\d+) //i )
		{
			my $server = $1;
			$server =~ tr/[A-Z]/[a-z]/;
			my $sendq = $3;

			if ( $server =~ /$conf{networkdomain}/i )
			{
				$data{uplinks}{$server} = $sendq;

				if ( $sendq > $conf{sendqwarn} )
				{
					my $diff = $sendq - $data{last}{sendq}{$server};
					if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

					queuemsg(2,"NOTICE \@$conf{channel} :WARNING: Detected high SendQ to $server: $sendq ($diff)");
					push_notify("SENDQ $server: $sendq ($diff)");
				}
			}
		}
		elsif ( $line =~ s/^236 $data{nick} //i )
		{
			# STATS v
			# Servername Uplink Flags Hops Numeric/Numeric Lag RTT Up Down Clients/Max Proto LinkTS Info    
			$line =~ s/( |	)+/ /g;
			my ( $srcsrv,$dstsrv,$flags,$hops,$numeric1,$numeric2,$lag,$rtt,$up,$down,$clients,$maxclients,$proto,$linkts,$info ) = split(/ /,$line);
			$srcsrv =~ tr/[A-Z]/[a-z]/;
			$dstsrv =~ tr/[A-Z]/[a-z]/;

			if ( $srcsrv =~ /servername/ )
			{
				# ignore;
			}
			else
			{
				$data{statsv}{$srcsrv}{uplink}   = $dstsrv;
				$data{statsv}{$srcsrv}{users}    = $clients;
				$data{statsv}{$srcsrv}{maxusers} = $maxclients;
				$data{statsv}{$srcsrv}{linkts}   = $linkts;
				$data{statsv}{$srcsrv}{hub}      = 0;

				if ( $flags =~ /H/ )
				{
					$data{statsv}{$srcsrv}{hub} = 1;
				}
			}

			if ( $dstsrv =~ /$data{servername}/i && $srcsrv !~ /$data{servername}/i && !exists $data{uplinks}{$srcsrv} )
			{
				$data{uplinks}{$srcsrv} = "n/a";
			}
		}
		elsif ( $line =~ /^219 $data{nick} / )
		{
			# end of STATS
			if ( $data{status}{statsc} )
			{
				$data{time}{statsv} = time;
				$data{status}{statsv} = 1;
				$data{time}{statsl} = time;
				$data{status}{statsl} = 1;
			}
			else
			{
				$data{time}{statsc} = time;
				$data{status}{statsc} = 1;
				foreach( keys %{$data{clines}} )
				{
					queuemsg(1,"RPING $_");
				}
			}
		}
		elsif ( $line =~ /^RPONG $data{nick} (.*) (\d+) :/ )
		{
			my $hub = $1;
			my $rping = $2;
			$hub =~ tr/[A-Z]/[a-z]/;
			if ( $rping > $conf{rpingwarn} && $rping > $data{clines}{$hub} )
			{
				my $diff = $rping - $data{clines}{$hub};
				if ( $diff =~ /^\d+$/ ) { $diff ="+$diff"; }

				queuemsg(2,"NOTICE \@$conf{channel} :WARNING: Detected high RPING for $hub: $rping ($diff)");
				push_notify("RPING $hub: $rping ms ($diff)");
			}

			$data{clines}{$hub} = $2;

		}
		elsif ( $line =~ s/^NOTICE (.*) :\*\*\* Notice -- //i )
		{
			if ( $line =~ /^client connecting:/i )
			{
				$data{notice}{more}++;
				$data{lusers}{locusers}++;
				my $time = time;
				$data{notice}{move}{$time}++;
			}
			elsif ( $line =~ /^client exiting:/i )
			{
				$data{notice}{less}++;
				$data{lusers}{locusers}--;
				my $time = time;
				$data{notice}{move}{$time}--;
			}
			elsif ( $line =~ /^Failed OPER attempt by (.*) \((.*)\)$/i )
			{
				my $failnick = $1;
				my $failhost = $2;

				$data{operfail}{$failhost}++;
				queuemsg(2,"NOTICE \@$conf{channel} :OPER Failed for $failnick\!$failhost ($data{operfail}{$failhost})");
				if ( $data{operfail}{$failhost} >= $conf{operfailmax} )
				{
					delete $data{operfail}{$failhost};
					if ( $conf{operfailaction} =~ /kill/i )
					{
						queuemsg(2,"KILL $failnick :$conf{operfailreason}");
					}
					elsif ( $conf{operfailaction} =~ /gline/i )
					{
						queuemsg(2,"GLINE +$failhost $conf{operfailgtime} :$conf{operfailreason}");
					}
				}
				else
				{
					queuemsg(2,"NOTICE $failnick :$conf{operfailwarn}");
				}
			}
			elsif ( $line =~ /^(.*) \((.*)\) is now operator \((.)\)$/ )
			{
				my $opernick = $1;
				my $operhost = $2;
				my $opermode = "GlobalOPER";
				if ( $3 =~ /o/ )
				{
					$opermode = "LocalOPER";
				}

				queuemsg(2,"NOTICE \@$conf{channel} :$opernick\!$operhost is now $opermode");
				if ( !($opernick =~ /^$data{nick}$/i ))
				{
					queuemsg(2,"INVITE $opernick $conf{channel}");
				}
			}
			elsif ( $line =~ /^Net junction: (.*) (.*)$/ )
			{
				queuemsg(3,"NOTICE \@$conf{channel} :NETJOIN $1 $2");

				my $notify = 0;
				my $server1 = $1;
				my $server2 = $2;

				if ( $server1 =~ /$data{servername}/i || $server2 =~ /$data{servername}/i )
				{
					$notify = 1;
				}

				foreach ( @{$conf{splitlist}} )
				{
					if ( $server1 =~ /$_/i || $server2 =~ /$_/i )
					{
						$notify = 1;
					}
				}

				if ( $notify )
				{
					push_notify("NETJOIN $server1 $server2");
				}
			}
			elsif ( $line =~ /^Net break: (.*) (.*)$/ )
			{
				queuemsg(3,"NOTICE \@$conf{channel} :NETQUIT $1 $2");

				my $notify = 0;
				if ( $1 eq $data{servername} || $2 eq $data{servername} )
				{
					$notify = 1;
				}

				foreach ( @{$conf{splitlist}} )
				{
					if ( $1 eq $_ || $2 eq $_ )
					{
						$notify = 1;
					}
				}

				if ( $notify )
				{
					push_notify("NETQUIT $1 $2");
				}
			}
		}
		elsif ( $line =~ /NOTICE $data{nick} :Highest connection count: \d+ \((\d+) clients\)$/ )
		{
			if ( !$conf{hubmode} )
			{
				$data{lusers}{maxusers} = $1;
				$data{status}{lusers} = 1;
				queuemsg(1,"MODE $conf{channel} +l $data{lusers}{maxusers}");
			}
		}
	}
	elsif ( $line =~ /^PING :(.*)/ )
	{
		queuemsg(1,"PONG :$1");
	}
	elsif ( $line =~ /^ERROR (.*)/ )
	{
		logmsg("ERROR from server: $1");
		queuemsg(1,"QUIT :ERROR FROM SERVER");
		delete $server{socket};
	}
}

sub get_nick
{
	my $nick = '';
	if ( $conf{nicks}[$conf{nickpos}] )
	{
		$nick = $conf{nicks}[$conf{nickpos}];
		$conf{nickpos}++;
	}
	else
	{
		$conf{nickpos}=0;
		$conf{nicksuffix}++;
		$nick = $conf{nicks}[$conf{nickpos}] . $conf{nicksuffix};
	}
	return $nick;
}

sub write_irc
{
	my $sock = $server{socket};
	my $msg;

	if ( $server{out1}[0] )
	{
		$msg  = shift(@{$server{out1}});
	}
	elsif ( $server{out2}[0] )
	{
		$msg = shift(@{$server{out2}});
	}
	elsif ( $server{out3}[0] )
	{
		$msg = shift(@{$server{out3}});
	}

	if ( $msg && $sock )
	{
		print $sock "$msg\r\n";
		logdeb("-> $msg");
	}
}

sub read_irc
{
	my $xdata = $server{data};
	if ( select($xdata, undef, undef, 0.05) )
	{
		if ( vec($xdata,fileno($server{socket}),1) )
		{
			my $tmp;
			sysread($server{socket},$tmp,262144);
			$server{bufin} .= $tmp;

			while( $server{bufin} =~ s/(.*)(\n)// )
			{
				my $line = $1;
				$line =~ s/(\r|\n)+$//;
				push(@{$server{in}},$line);
				if ( $line =~ /Client (connecting|exiting): / || $line =~ / 354 / ) { #ignore;
				} else { logdeb("<- $line"); }

			}
		}
	}
}

sub connect_irc
{
	$server{socket} = IO::Socket::INET->new (
		Proto		=> 'tcp',
		LocalAddr	=> $conf{vhost},
		PeerAddr	=> $conf{serverip},
		PeerPort	=> $conf{serverport},
		Blocking	=> 0,
		Reuse		=> 1,
	);

	if ( $server{socket} )
	{
		$server{data} = '';
		vec($server{data},fileno($server{socket}),1) = 1;
		return 1;
	}
	else
	{
		return 0;
	}
}

sub load_config
{
	my $config  = shift;

	if ( !$config )
	{
		logerr("syntax: $0 /path/to/configfile.conf");
		exit 1;
	}
	elsif ( $config =~ /^\// && -r "$config" && -f "$config" )
	{
		my %newconf;
		open(CONFIG,"$config");
		while(<CONFIG>)
		{
			chop;

			if ( /^((\w|_)+)(	| )+(.*)/ )
			{
				my $name = $1;
				my $value = $4;
				$name =~ tr/[A-Z]/[a-z]/;

				logdeb("CONFIG $name -> $value");

				if ( $name eq 'nick' )
				{
					foreach(split(/,/,$value))
					{
						push(@{$newconf{nicks}},$_);
					}
					$newconf{nickpos} = 0;
				}
				elsif ( $name eq 'permitip' )
				{
					push(@{$newconf{ippermit}},$value);
				}
				elsif ( $name eq 'rnameexcept' )
				{
					push(@{$newconf{rnamelist}},$value);
				}
				elsif ( $name eq 'ipexcept' )
				{
					push(@{$newconf{iplist}},$value);
				}
				elsif ( $name eq 'pushuser' )
				{
					push(@{$newconf{usertoken}},$value);
				}
				elsif ( $name eq 'pushnetsplit' )
				{
					push(@{$newconf{splitlist}},$value);
				}
				elsif ( $name eq 'dcclisten' )
				{
					if ( $value =~ /^(\d+\.\d+\.\d+\.\d+|)$/ )
					{
						push(@{$newconf{dccips}},$value);
					}
				}
				$newconf{$name}=$value;
			}
		}
		close(CONFIG);

		# checking config settings

		my @ECONF;

		if ( !( $newconf{serverip} =~ /^\d+\.\d+\.\d+\.\d+$/ ) )
		{ push(@ECONF,"SERVERIP"); }
		if ( !( $newconf{serverport} =~ /^\d+$/ ) )
		{ push(@ECONF,"SERVERPORT"); }
		if ( !( $newconf{vhost} =~ /^(\d+\.\d+\.\d+\.\d+|)$/ ) )
		{ push(@ECONF,"VHOST"); }
		if ( !( $newconf{hubmode} =~ /^(0|1)$/i ) )
		{ push(@ECONF,"HUBMODE"); }
		if ( !( $newconf{timeout} =~ /^\d+$/ ) )
		{ push(@ECONF,"TIMEOUT"); }
		if ( !( $newconf{dccenable} =~ /^\d+$/ ) )
		{ push(@ECONF,"DCCENABLE"); }
		if ( !( $newconf{dccport} =~ /^\d+$/ ) )
		{ push(@ECONF,"DCCPORT"); }
		if ( !( $newconf{nick} =~ /^(,|\w)+$/i ) )
		{ push(@ECONF,"NICK"); }
		if ( !( $newconf{ident} =~ /^\w+$/i ) )
		{ push(@ECONF,"IDENT"); }
		if ( !( $newconf{operuser} =~ /^.+$/ ) )
		{ push(@ECONF,"OPERUSER"); }
		if ( !( $newconf{operpass} =~ /^.+$/ ) )
		{ push(@ECONF,"OPERPASS"); }
		if ( !( $newconf{channel} =~ /^\&\w+$/i ) )
		{ push(@ECONF,"CHANNEL"); }
		if ( !( $newconf{networkdomain} =~ /^(\w|\.|\-|\_)+$/i ) )
		{ push(@ECONF,"NETWORKDOMAIN"); }

		if ( !( $newconf{trafficreport} =~ /^(0|1)$/i ) )
		{ push(@ECONF,"TRAFFICREPORT"); }

		if ( $newconf{operfailmax} =~ /^\d+$/ )
		{
			if ( $newconf{operfailmax} > 0 ) {
				if ( !( $newconf{operfailwarn} =~ /^.+$/ ) )
				{ push(@ECONF,"OPERFAILWARN"); }
				if ( !( $newconf{operfailaction} =~ /^(KILL|GLINE)$/i ) )
				{ push(@ECONF,"OPERFAILACTION"); }
				if (
					$newconf{operfailaction} =~ /GLINE/i
				&&
					!( $newconf{operfailgtime} =~ /^\d+$/ )
				)
				{ push(@ECONF,"OPERFAILGTIME"); }
				if ( !( $newconf{operfailreason} =~ /^.+$/ ) )
				{ push(@ECONF,"OPERFAILREASON"); }
			}
		} else { push(@ECONF,"OPERFAILMAX"); }

		if ( !( $newconf{reportenable} =~ /^(0|1)$/i ) )
		{ push(@ECONF,"REPORTENABLE"); }

		if ( !( $newconf{locglineaction} =~ /^(GLINE|WARN|DISABLE)$/i ) )
		{ push(@ECONF,"LOCGLINEACTION"); }
		if ( !( $newconf{rnameglinetime} =~ /^\d+$/ ) )
		{
			push(@ECONF,"RNAMEGLINETIME");
		}
		else
		{
			if ( !($newconf{rnameglinelimit} =~ /^\d+$/ ) )
			{ push(@ECONF,"RNAMEGLINELIMIT"); }
		}

		if ( !( $newconf{ipglinetime} =~ /^\d+$/ ) )
		{
			push(@ECONF,"IPGLINETIME");
		}
		else
		{
			if ( !($newconf{ipglinelimit} =~ /^\d+$/ ) )
			{ push(@ECONF,"IPGLINELIMIT"); }
		}


		if ( !( $newconf{ceuserthres} =~ /^\d+$/ ) )
		{ push(@ECONF,"CEUSERTHRES"); }
		if ( !( $newconf{cetimethres} =~ /^\d+$/ ) )
		{ push(@ECONF,"CETIMETHRES"); }

		if ( !( $newconf{rname} =~ /^.+$/ ) )
		{ push(@ECONF,"RNAME"); }

		if ( !( $newconf{pushenable} =~ /^(0|1)$/i ) )
		{ push(@ECONF,"PUSHENABLE"); }

		if ( !( $newconf{pushtoken} =~ /^.+$/ ) )
		{ push(@ECONF,"PUSHTOKEN"); }

		if ( !( $newconf{rpingwarn} =~ /^.+$/ ) )
		{ push(@ECONF,"RPINGWARN"); }

		if ( !( $newconf{sendqwarn} =~ /^.+$/ ) )
		{ push(@ECONF,"SENDQWARN"); }

		if ( $newconf{version} ne $version )
		{ push(@ECONF,"VERSION MISMATCH!"); }

		if ( !-w "$newconf{path}" || !-d "$newconf{path}" )
		{ push(@ECONF,"PATH, cannot write to $newconf{path}"); }

		if ( @ECONF )
		{
			foreach(@ECONF)
			{
				logerr("Error in configuration file for directive \"$_\"");
			}
			logerr("Aborting...");
			exit 1;
		}

		if ( $newconf{trafficreport} )
		{
			# guessing the OS
			my $os = `uname -s`; chop $os;
			my $rel = `uname -r`; chop $rel;

			if ( $os =~ /FreeBSD/i )
			{
				$newconf{trafficsub} = 'fbsd';
			}
			elsif ( $os =~ /Linux/i )
			{
				if ( $rel =~ /^2.(2|4|6)/ )
				{
					$newconf{trafficsub} = 'linux';
				}
				else
				{
					logmsg("TRAFFICREPORT: $os-$rel is NOT supported. Feature disabled.");
					$newconf{trafficreport} = 0;
				}
			}
			else
			{
				logmsg("TRAFFICREPORT: $os-$rel is NOT supported. Feature disabled.");
				$newconf{trafficreport} = 0;
			}
		}
		return %newconf;
	}
	else
	{
		logerr("cannot read file, aborting...");
		exit 1;
	}
}

sub logdeb
{
	if ( $debug )
	{
		printf("%s DEBUG : %s\n",unix2date(time),(shift));
	}
}

sub logmsg
{
	if ( $debug || !exists $conf{path} )
	{
		printf("%s LOG   : %s\n",unix2date(time),(shift));
	}
	else
	{
		open(LOGFILE,">>$conf{path}/var/debug.log");
		print LOGFILE sprintf("%s LOG   : %s\n",unix2date(time),(shift));
		close(LOGFILE);
	}
}

sub logerr
{
	if ( $debug || !exists $conf{path} )
	{
		printf("%s ERROR : %s\n",unix2date(time),(shift));
	}
	else
	{
		open(LOGFILE,">>$conf{path}/var/debug.err");
		print LOGFILE sprintf("%s ERROR : %s\n",unix2date(time),(shift));
		close(LOGFILE);
	}
}

sub easytime {

	my $total = shift;
	my $sign = '';
	if ( $total =~ /^-/ )
	{
		$sign = '-';
		$total =~ s/^-//;
	}

	my $sec = $total % 60;
	$total = ($total-$sec)/60;

	my $min = $total % 60;
	$total = ($total-$min)/60;

	my $hour = $total % 24;
	$total = ($total-$hour)/24;

	my $day  = $total % 7;
	$total = ($total-$day)/7;

	my $week = $total;

	if    ($week) { return sprintf("%s%d" . "w" . "%d" . "d" . "%d" . "h",$sign,$week,$day,$hour); }
	elsif ($day)  { return sprintf("%s%d" . "d" . "%d" . "h" . "%d" . "m",$sign,$day,$hour,$min);  }
	else	  { return sprintf("%s%d" . "h" . "%d" . "m" . "%d" . "s",$sign,$hour,$min,$sec);  }

}

sub daemonize
{
	if ( defined ( my $pid = fork() ) )
	{
		if ( $pid )
		{
			# I'm daddy
			print "GenEthic v$conf{version} started.\n";
			exit;
		}
		else
		{
			# I'm junior
			chdir "/";
			open STDIN, '/dev/null';
			open STDOUT, '>>/dev/null';
			open STDERR, '>>/dev/null';
			setsid;
			umask 0;
		}
	}
	else
	{
		print STDERR "Can't fork $!\n";
		exit 1;
	}
}

sub writemsg
{
	my $file = shift;
	my $msg  = shift;
	open(FILE,">>$conf{path}/var/$file.txt") || warn "Cannot write to $conf{path}/var/$file.txt";
	print FILE sprintf("%s %s\n",time,$msg);
	close(FILE);
}

sub guess_tz
{
	my $usertime = shift;
	$usertime =~ s/(	| )+/ /g;

	if ( $usertime =~ /GMT(\+|\-)(\d+)/ )
	{
		my $offset = "$1$2";
		return $offset * 3600;
	}
	elsif ( $usertime =~ /(\+|\-)(\d{4})/ )
	{
		my $offset = "$1$2";
		return $offset * 36;
	}
	# Fri, 26 Apr 2024 13:44:04 +0100
	elsif ( $usertime =~ /(\w{3}), (\d{1,2}) (\w{3}) (\d{4}) (\d+):(\d+):(\d+)$/ )
	{
		my $day = $2;
		my $mon = $3;
		my $year = $4;
		my $hour = $5;
		my $min  = $6;
		my $sec  = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		return timegm($sec,$min,$hour,$day,$mon,$year) - time;
	}
	# Fri Apr 26 13:56:48 2024
	elsif ( $usertime =~ /(\w{3}) (\w{3}) (\d{1,2}) (\d+):(\d+):(\d+) (\d{4})$/ )
	{
		my $mon = $2;
		my $day = $3;
		my $hour = $4;
		my $min  = $5;
		my $sec  = $6;
		my $year = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		return timegm($sec,$min,$hour,$day,$mon,$year) - time;
	}
	# Fri 26th Apr 2024 03:07p
	elsif ( $usertime =~ /(\w{3}) (\d{1,2})(\w{2}) (\w{3}) (\d{4}) (\d+):(\d+)(\w{1})$/ )
	{
		my $day = $2;
		my $mon = $4;
		my $year = $5;
		my $hour = $6;
		my $min  = $7;

		$mon =~ s/jan/1/i;
		$mon =~ s/feb/2/i;
		$mon =~ s/mar/3/i;
		$mon =~ s/apr/4/i;
		$mon =~ s/may/5/i;
		$mon =~ s/jun/6/i;
		$mon =~ s/jul/7/i;
		$mon =~ s/aug/8/i;
		$mon =~ s/sep/9/i;
		$mon =~ s/oct/10/i;
		$mon =~ s/nov/11/i;
		$mon =~ s/dec/12/i;
		$mon--;

		if ( $8 eq "p")
		{
			$hour = $hour + 12;
		}

		return timegm(0,$min,$hour,$day,$mon,$year) - time;
	}
	else
	{
		return 0;
	}
}

sub init_dcc
{
	my ($userip,$userport) = @_;
	my $dccport  = 0;
	if ( $conf{dccport} )
	{
		$dccport = $conf{dccport};
	}
	elsif ( $userport )
	{
		$dccport = $userport;
	}
	
	my $dccsock;

	if ( $dccport )
	{
#		$dccsock = IO::Socket::INET->new (
		$dccsock = new IO::Socket::INET (
			Proto		=> 'tcp',
			LocalPort	=> $dccport,
			LocalHost	=> $userip,
#			LocalAddr	=> $userip,
			Timeout		=> 30,
			Listen		=> 1,
			Reuse		=> 1 );
	}
	else
	{
		$dccsock = IO::Socket::INET->new (
			Proto		=> 'tcp',
			LocalAddr	=> $userip,
			Timeout		=> 10,
			Listen		=> 1,
			Reuse		=> 1 );
	}

#	$SIG{INT} = sub { $dccsock->close(); exit 0; }

	if ( $dccsock && !$@ )
	{
		return ( $dccsock, $dccsock->sockport() );
	}
	else
	{
		return 0;
	}
}

sub dcc
{
	my $socket = shift;
	my $code   = shift;
	my $offset = shift;

	my $dcctimeout = 3600;
	my $dccwarn    = 3300;
	my $lastin     = time;
	my $warned     = 0;

	# lets go away now.
	if ( !( my $pid = fork() ) )
	{
		# I am junior
		
		if ( my $client = $socket->accept() )
		{
			shutdown($socket,2);

			my $wdata;
			vec($wdata,fileno($client),1) = 1;

			print $client "Password?\n";
			my $auth = 0;

			open(DCCLOG,">>$conf{path}/var/dcc.log");
			print DCCLOG sprintf("[%s] %s: connect\n",unix2date(time),$client->peerhost);

			while(fileno($client))
			{
				my $xdata = $wdata;
				my $line  = '';
				if ( select($xdata, undef, undef, 0.25) )
				{
					if (vec($xdata, fileno($client), 1))
					{
						$line = <$client>;
						$line =~ s/(\r|\n)+$//;
						if ( $line =~ /./ ) { # got something...
						}
						else
						{
							print DCCLOG sprintf("[%s] %s: connection reset by peer\n",unix2date(time),$client->peerhost);
							exit;
						}
					}
				}
				if ( $line )
				{
					print DCCLOG sprintf("[%s] %s: command: %s\n",unix2date(time),$client->peerhost,$line);
					$lastin = time;
					$warned = 0;

					$line =~ s/  / /g;
					$line =~ s/^ //;
					$line =~ s/ $//;

					if ( !$auth )
					{
						if ( $line eq $code )
						{
							$auth = 1;
							print DCCLOG sprintf("[%s] %s: authenticated\n",unix2date(time),$client->peerhost);
							print $client "GenEthic v$conf{version} DCC Interface\n";

							my $eoff = easytime($offset);
							if ( $eoff =~ /^\d/ ) { $eoff = "+$eoff"; }
							print $client "Your GMT offset is $eoff\n";
							print $client "note: you can change your GMT offset at any time with the 'TZ' command, see 'HELP TZ'\n";
							print $client "\n";
							print $client "WARNING: please choose carefully the search options. Otherwise you risk to be flooded by thousands of messages!\n";
							print $client "\n";
							print $client "enter 'HELP' for help ;)\n";
						}
						else
						{
							print DCCLOG sprintf("[%s] %s: wrong password\n",unix2date(time),$client->peerhost);
							print $client "password mismatch, bye\n";
							shutdown($client,2);
							exit;
						}
					}
					elsif ( $line =~ s/^help *//i )
					{
						if ( $line =~ /^tz$/i )
						{
							print $client "HELP: command 'TZ'\n";
							print $client "change the GMT offset, in order to display all timestamps in your local time.\n";
							print $client "syntax  : TZ <+/-><OFFSET>\n";
							print $client "example : TZ +1\n";
							print $client "Will set you in GMT+1\n";
						}
						elsif ( $line =~ /^notice$/i )
						{
							print $client "HELP: command 'NOTICE'\n";
							print $client "commands syntax.\n";
							print $client "syntax  : NOTICE <match> [optional match]\n";
							print $client "example : NOTICE KILL spale\n";
							print $client "shows all servers notices comtaining 'KILL' and 'spale'\n";
						}
						elsif ( $line =~ /^help$/i )
						{
							print $client "HELP: command 'HELP'\n";
							print $client "the commands syntax.\n";
							print $client "syntax  : HELP [command]\n";
							print $client "example : HELP TZ\n";
							print $client "shows the syntax of the 'TZ' command.\n";
						}
						elsif ( $line =~ /^hack$/i )
						{
							print $client "HELP: command 'HACK'\n";
							print $client "logs of HACK notices matching a given string.\n";
							print $client "syntax  : HACK <string>\n";
							print $client "example : HACK #channel\n";
							print $client "shows all HACK notices containing the string '#channel'.\n";
						}
						elsif ( $line =~ /^quit$/i )
						{
							print $client "HELP: command 'QUIT'\n";
							print $client "Ends the DCC session.\n";
							print $client "syntax  : QUIT\n";
						}
						elsif ( $line =~ /^gline$/i )
						{
							print $client "HELP: command 'GLINE'\n";
							print $client "logs of GLINE notices matching a given string.\n";
							print $client "syntax  : GLINE <string>\n";
							print $client "example : GLINE 10.20.30.40\n";
							print $client "shows all GLINE notices containing the string '10.20.30.40'.\n";
						}
						elsif ( $line =~ /^conn$/i )
						{
							print $client "HELP: command 'CONN'\n";
							print $client "last n connections/disconnections.\n";
							print $client "syntax  : CONN <number>\n";
							print $client "example : CONN 300\n";
							print $client "shows the last 300 connections/disconnections.\n";
						}
						elsif ( $line =~ /^scan$/i )
						{
							print $client "HELP: command 'SCAN'\n";
							print $client "scan the local users.\n";
							print $client "syntax  : SCAN <NICK|USER|HOST|IP|RNAME|XUSER||IDLE|MODE> <string>\n";
							print $client "note    : ? and * wildcards allowed.\n";
							print $client "example : SCAN RNAME *irc*\n";
							print $client "shows all the users having the string 'irc' in their realname field.\n";
						}
						elsif ( $line =~ /^clones$/i )
						{
							print $client "HELP: command 'CLONES'\n";
							print $client "scan the local users for similar entries.\n";
							print $client "syntax  : CLONES\n";
						}
						elsif ( $line =~ /^map$/i )
						{
							print $client "HELP: command 'MAP'\n";
							print $client "show a map of servers ordered by number of clients.\n";
							print $client "syntax  : MAP\n";
						}
						else
						{
							print $client "Available commands are: (use HELP <command> for more details)\n";
							print $client "HELP, TZ, HACK, CONN, GLINE, NOTICE, SCAN, CLONES, MAP, QUIT\n";
						}
						
					}
					elsif ( $line =~ /^notice +(.*)$/i )
					{
						my $arg1 = $1;
						my $arg2 = '';

						if ( $arg1 =~ / / )
						{
							($arg1,$arg2) = split(/ /,$arg1);
						}

						$arg1 = wild2reg($arg1);
						$arg2 = wild2reg($arg2);

						my $all = 0;
						my $count = 0;

						open(NOTICE,"$conf{path}/var/notice.txt");
						while(<NOTICE>)
						{
							chop;
							if ( /$arg1/ )
							{
								my $match = 0;
								if ( $arg2 )
								{
									if ( /$arg2/i )
									{
										$match = 1;
									}
								}
								else
								{
									$match = 1;
								}
								if ( $match )
								{
									if ( /(\d+) (.*)$/ )
									{
										print $client sprintf("[%s] %s\n",unix2date($1),$2);
										$count++;
									}
								}
							}
						
							$all++;
						}
						close(NOTICE);

						print $client "Found $count of $all notices.\n";
					}
					elsif ( $line =~ /^clones$/i )
					{
						if ( $conf{hubmode} || $conf{locglineaction} =~ /disable/i )
						{
							print $client "This function is disabled in hub mode or when locglineaction is disabled\n";
						}
						else
						{
							my $all = 0;

							my $whots = unix2date((stat("$conf{path}/var/users.txt"))[9],$offset);
							print $client "User base last updated at $whots\n";
							print $client "Loading user base ...\n";

							my %a;
							my %c;

							$c{user}  = "numbers are replaced by '?'";
							$c{ip}    = "ip addresses are summarized by C classes";
							$c{host}  = "hostnames are summarized by domain.tld";
							$c{nick}  = "nicknames are summarized by their 4 first chars and numbers are replaced by '?'";
							$c{idle}  = "idle times are splitted into 4 ranges. 0-1h,1h-1d,1d-1w,1w+";
							$c{rname} = "color/control codes are replaced by ^C/^B/^U/^R";


							open(FILE,"$conf{path}/var/users.txt");
							while(<FILE>)
							{
								chop;
								my %u;
								($u{user},$u{ip},$u{host},$u{nick},$u{idle},$u{xuser},$u{rname})=split(/	/);

								$u{user} =~ s/\d/?/g;
								$u{ip}   =~ s/\.\d+$/\.\*/;

								if ( $u{host} =~ /\.\d+$/ )
								{
									$u{host} = 'no hostname';
								}
								else
								{
									$u{host} =~ s/.*\.((\w|\_|\-)+)\.(\w+)$/\*.$1.$3/;
								}

								$u{nick} =~ s/\d/\?/g;
								$u{nick} =~ s/^(....).*/$1\*/;

								if ( $u{idle} > 604800 )
								{ $u{idle} = '> 1w'; }
								elsif ( $u{idle} > 86400 )
								{ $u{idle} = '1d - 1w'; }
								elsif ( $u{idle} > 3600 )
								{ $u{idle} = '1h - 1d'; }
								else
								{ $u{idle} = '< 1h'; }

								if ( $u{xuser} ) { $u{xuser} = 1; }

								$u{rname} =~ s//^C/g;
								$u{rname} =~ s//^U/g;
								$u{rname} =~ s//^B/g;
								$u{rname} =~ s//^R/g;

								foreach(split(/ /,"user ip host nick idle xuser rname"))
								{
									push(@{$a{$_}},$u{$_});
								}
								$all++;

							}
							close(FILE);

							print $client "Sorting results ...\n";

							my $xuser = 0;
							foreach(@{$a{xuser}}) { if ( $_ ) { $xuser++; } }
							print $client "found $xuser users of $all logged into X\n";

							my $type;
							foreach $type (split(/ /,"user host ip nick idle rname"))
							{
								print $client "Results for '$type' ($c{$type})\n";

								my %u;
								foreach ( @{$a{$type}} )
								{
									$u{$_}++;
								}

								my @TEMP;
								foreach ( keys %u )
								{
									push(@TEMP,sprintf("%05d	%s",$u{$_},$_));
								}
								my $limit = 10;
								foreach ( reverse sort @TEMP )
								{
									if ( $limit > 0 )
									{
										my ($no,$msg)=split(/	/,$_);
										$no+=0;
										print $client sprintf("%5s -> %s\n",$no,$msg);
									}
									$limit--;
								}
							}
							print $client "done.\n";
						}
					}
					elsif ( $line =~ /^map$/ )
					{
						my $mapts = unix2date((stat("$conf{path}/var/map.txt"))[9],$offset);
						print $client "MAP last updated at $mapts\n";

						my @MAP;
						open(MAP,"$conf{path}/var/map.txt");
						while(<MAP>)
						{
							chop;
							my ($serv,$users) = split(/ /);
							push(@MAP,sprintf("%05s %s",$users,$serv));
						}
						close(MAP);
						foreach(reverse(sort(@MAP)))
						{
							my($users,$serv) = split(/ /);
							$users += 0;
							if ( $users > 5 )
							{
								print $client sprintf("%5s %s\n",$users,$serv);
							}
						}
						print $client "done.\n";
					}
					elsif ( $line =~ /^scan (nick|user|host|ip|rname|idle|xuser|mode) (.*)$/i )
					{
						if ( $conf{hubmode} || $conf{locglineaction} =~ /disable/i )
						{
							print $client "This function is disabled in hub mode or when locglineaction is disabled.\n";
						}
						else
						{
							my $field = $1;
							my $match = wild2reg($2);

							$field =~ tr/[A-Z]/[a-z]/;

							my $whots = unix2date((stat("$conf{path}/var/users.txt"))[9],$offset);
							print $client "User base last updated at $whots\n";

							my $count = 0;
							my $all   = 0;

							open(FILE,"$conf{path}/var/users.txt");
							while(<FILE>)
							{
								chop;
								my %u;
								($u{user},$u{ip},$u{host},$u{nick},$u{idle},$u{xuser},$u{rname},$u{mode})=split(/	/);
								$all++;

								if ( $u{$field} =~ /^$match$/i )
								{
									$count++;
									my $idle = easytime($u{idle});
									print $client "$u{nick}\!$u{user}\@$u{host} [$u{ip}] mode:$u{mode} idle:$idle Xuser:$u{xuser} ($u{rname})\n";
								}
							}
							close(FILE);
							print $client "Found $count users of $all users.\n";
						}
					}
					elsif ( $line =~ /^conn (\d+)$/i )
					{
						my $num = $1;
						my @CONN;
						my $count = 0;
						open(CONN,"$conf{path}/var/connexit.txt");
						while(<CONN>)
						{
							chop;
							$count++;
							push(@CONN,$_);
						}
						close(CONN);

						my $start = $count - $num;
						if ( $start < 0 ) { $start = 0; }

						for ( my $id = $start; $id <= $count; $id++ )
						{
							my $msg = $CONN[$id];
							if ( $msg =~ /^(\d+) (CONN|EXIT):(.*):(.*):\[(.*)\]:.....:(\w*):(.*)$/ )
							{
								my $ts       = $1;
								my $type     = $2;
								my $nick     = $3;
								my $userhost = $4;
								my $ip       = $5;
								my $class    = $6;
								my $txt      = $7;

								print $client sprintf("[%s] %s %s\!%s %s class:%s (%s)\n",unix2date($ts,$offset),$type,$nick,$userhost,$ip,$class,$txt);

							}
						}
						print $client "END\n";
					}
					elsif ( $line =~ /^gline (.*)$/ )
					{
						my $match = wild2reg($1);
						my $count = 0;
						my $all   = 0;
						open(GLINE,"$conf{path}/var/gline.txt");
						while(<GLINE>)
						{
							chop;
							if ( /$match/i && /^(\d+) (global|local):(.*):(.*\@.*|\$R.*):(\d+):(.*)$/ )
							{
								my $ts1  = $1;
								my $mode = $2;
								my $serv = $3;
								my $user = $4;
								my $ts2  = $5;
								my $msg  = $6;

								$serv =~ s/\.$conf{networkdomain}//;

								print $client sprintf("[%s - %s] %6s %s glined %s (%s)\n",unix2date($ts1,$offset),unix2date($ts2,$offset),$mode,$serv,$user,$msg);
								$count++;
							}
							$all++;
						}
						close(GLINE);
						print $client "Found $count glines of $all glines.\n";
					}
					elsif ( $line =~ /^hack (.*)$/i )
					{
						my $match = wild2reg($1);
						my $count = 0;
						my $all   = 0;
						open(HACK,"$conf{path}/var/hack.txt");
						while(<HACK>)
						{
							chop;
							if ( /^(\d+) (\d):(\d+):(.*)$/ )
							{
								my $ts1  = $1;
								my $mode = $2;
								my $ts2  = $3;
								my $msg  = $4;
								if ( $msg =~ /$match/i )
								{
									if ( $mode eq 2 || $mode eq 3 )
									{
										$mode = "DESYNC  HACK($mode)";
									}
									elsif ( $mode eq 4 )
									{
										$mode = "SERVICE HACK($mode)";
									}
									else
									{
										$mode = "UNKNOWN HACK($mode)";
									}
									print $client sprintf("[%s] %s %s (%s)\n",unix2date($ts1,$offset),$mode,$msg,easytime($ts1-$ts2));
									$count++;
								}
							}
							$all++;
						}
						close(HACK);
						print $client "Found $count hack of $all hack.\n";
					}
					elsif ( $line =~ /^tz (\-|\+)(\d+)$/i )
					{
						$offset = "$1$2" * 3600;
						my $eoff = easytime($offset);
						if ( $eoff =~ /^\d/ ) { $eoff = "+$eoff"; }
						print $client "Your offset to GMT is now $eoff\n";
					}
					elsif ( $line =~ /^quit$/i )
					{
						print DCCLOG sprintf("[%s] %s: quit\n",unix2date(time),$client->peerhost);
						print $client "Thanks for using GenEthic v$conf{version}, bye!\n";
						exit;
					}
					else
					{
						print $client "no such command, missing or invalid argument(s), try 'HELP'\n";
					}

				}

				if ( time - $lastin >= $dccwarn && !$warned )
				{
					print $client sprintf("WARNING, session will timeout in %s seconds.\n",$dcctimeout-$dccwarn);
					$warned = 1;
				}
				elsif ( time - $lastin >= $dcctimeout )
				{
					print DCCLOG sprintf("[%s] %s: timeout\n",unix2date(time),$client->peerhost);
					print $client "DCC timeout.\n";
					exit;
				}
			}
		}
		exit;
	}
	return 1;
}

sub gencode
{
	my $chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
	my $code = '';

	for(0..1)
	{
		my $charid = int(rand(length($chars)));
		my $char = $chars;
		$char =~ s/^.{$charid}(.).*/$1/;
		$code .= $char;
	}
	return $code;
}
sub cpu
{
	my %cpu;
	if ( $conf{trafficsub} eq 'fbsd' )
	{
		open(CPU,"/sbin/sysctl kern.cp_time |");
		while(<CPU>)
		{
			chop;
			if ( /^kern.cp_time: (\d+) (\d+) (\d+) (\d+) (\d+)$/ )
			{
				$cpu{used} = $1 + $2 + $3 + $4;
				$cpu{idle} = $5;
			}
		}
		close(CPU);
	}
	elsif ( $conf{trafficsub} eq 'linux' )
	{
		open(CPU,"/proc/stat");
		while(<CPU>)
		{
			chop;
			s/ +/ /g;
			if ( /^cpu (\d+) (\d+) (\d+) (\d+)$/ )
			{
				$cpu{used} = $1 + $2 + $3;
				$cpu{idle} = $4;
			}
		}
		close(CPU);
	}

	return %cpu;
}

sub traffic
{
	my %iftraffic;

	if ( $conf{trafficsub} eq 'fbsd' )
	{
		open(TRAF,"netstat -nib |");
		while(<TRAF>)
		{
			chop;
			if ( /^(\w+) +\d+ +<Link\#\d+> +\w\w:\w\w:\w\w:\w\w:\w\w:\w\w +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+) +(\d+)/i )
			{
				my $ifname = $1;
				if ( $ifname =~ /(lo|gif)\d+/ )
				{
					#ignored
				}
				else
				{
					$iftraffic{$ifname}{ip} = $2;
					$iftraffic{$ifname}{ib} = $4;
					$iftraffic{$ifname}{op} = $5;
					$iftraffic{$ifname}{ob} = $7;
				}
			}
		}
		close(TRAF);
	}
	elsif ( $conf{trafficsub} eq 'linux' )
	{
		open(TRAF,"/proc/net/dev");
		while(<TRAF>)
		{
			chop;
			s/^ +//;
			s/:/ /;
			s/ +/ /g;
			if ( /^(eth\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) / )
			{
				my $ifname = $1;
				$iftraffic{$ifname}{ip} = $3;
				$iftraffic{$ifname}{op} = $11;
				$iftraffic{$ifname}{ib} = $2;
				$iftraffic{$ifname}{ob} = $10;
			}
		}
		close(TRAF);
	}
	return %iftraffic;
}

sub unix2date
{
	my $ts = shift;
	$ts += shift || 0;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($ts);  

	$mon++;
	$year +=1900;

	return sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year,$mon,$mday,$hour,$min,$sec);
}

sub wild2reg
{
	my $wild = shift;

	$wild =~ s/(\\|\[|\]|\^|\$|\.|\+|\{|\})/\\$1/g;
	$wild =~ s/\*/\.\*/g;
	$wild =~ s/\?/\./g;

	return $wild;
}
