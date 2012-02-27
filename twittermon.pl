#!/usr/bin/perl
use strict;
use AnyEvent::Twitter::Stream;
use Getopt::Long;
use Sys::Syslog;
use Encode;
use utf8;
use POSIX qw(setsid);

my $program	= "twittermon.pl";
my $version	= "1.0";
my $debug;
my $help;
my $tweet;
my $cefDestination; # Send CEF events to this destination:port
my $cefPort = 514;
my $cefSeverity = 3;
my $caught = 0;
my @keywordList;
my $keyword;
my $pidFile = "/var/run/twittermon.pid";
my $configfile;
my $syslogFacility = "daemon";
my $dumpDir;
my %matches;
my $twitterUser;
my $twitterPass;

$SIG{'TERM'}	= \&sigHandler;
$SIG{'INT'}	= \&sigHandler;
$SIG{'KILL'}	= \&sigHandler;
$SIG{'USR1'}	= \&sigReload;

# Process arguments
my $result = GetOptions(
	"cef-destination=s"	=> \$cefDestination,
	"cef-port=s"		=> \$cefPort,
	"cef-severity=s"	=> \$cefSeverity,
	"debug"			=> \$debug,
	"facility=s"		=> \$syslogFacility,
	"help"			=> \$help,
	"pidfile=s"		=> \$pidFile,
	"config=s"		=> \$configfile,
	"twitter-user=s"	=> \$twitterUser,
	"twitter-pass=s"	=> \$twitterPass,
);

if ($help) {
	print <<__HELP__;
Usage: $0 --config=filepath [--facility=daemon ] [--debug] [--help]
                [--cef-destination=fqdn|ip] [--cef-port=<1-65535> [--cef-severity=<1-10>]
                [--pidfile=file] --twitter-user=username] 
                [--twitter-pass=password]
Where:
--cef-destination : Send CEF events to the specified destination (ArcSight)
--cef-port        : UDP port used by the CEF receiver (default: 514)
--cef-severity    : Generate CEF events with the specified priority (default: 3)
--debug           : Enable debug mode (verbose - do not detach)
--facility        : Syslog facility to send events to (default: daemon)
--help            : What you're reading now.
--pidfile         : Location of the PID file (default: /var/run/pastemon.pid)
--config          : Configuration file with keywords to match (send SIGUSR1 to reload)
--twitter-user    : Your Twitter username
--twitter-pass    : Your Twitter password
__HELP__
	exit 0;
}

($debug) && print STDERR "+++ Running in foreground.\n";

($cefDestination) && syslogOutput("Sending CEF events to $cefDestination:$cefPort (severity $cefSeverity)");

# Do not allow multiple running instances!
if (-r $pidFile) {
open(PIDH, "<$pidFile") || die "Cannot read pid file!";
my $currentpid = <PIDH>;
close(PIDH);
die "$program already running (PID $currentpid)";
}

loadKeywordsFromFile($configfile) || die "Cannot load keywords from file $configfile";
my $keywords = "";
for $keyword (@keywordList) {
	$keywords = $keywords . $keyword . ',';
}
# Twitter Steaming API limitation: track string cannot
# exceed 60 characters!
(length($keywords) > 60) && die "Keywords cannot exceed 60 characters. Please remove some keywords.";

if (!$debug) {
my $pid = fork;
die "Cannot fork" unless defined($pid);
exit(0) if $pid;

# We are the child
(POSIX::setsid != -1) or die "setsid failed";
chdir("/") || die "Cannot changed working directory to /";
#close(STDOUT);
#close(STDOUT);
close(STDIN);
}

syslogOutput("Running with PID $$");
open(PIDH, ">$pidFile") || die "Cannot write PID file $pidFile: $!";
print PIDH "$$";
close(PIDH);

my $done = AE::cv;

if ($debug) {
	binmode STDOUT, ":utf8";
	binmode STDERR, ":utf8";
}

# ---------
# Main loop
# ---------

my $streamer = AnyEvent::Twitter::Stream->new(
    username => $twitterUser,
    password => $twitterPass,
    method   => "filter",
    track    => $keywords,
    on_tweet => \&processTweet,
    on_error => sub {
        my $error = shift;
        warn "ERROR: $error";
        $done->send;
    },
    on_eof   => sub {
        $done->send;
    },
);

# uncomment to test undef $streamer
# my $t = AE::timer 1, 0, sub { undef $streamer };

$done->recv;

#
# Check for match tweet
#
sub processTweet {
	my $tweet = shift;

	# Sanitize tweets
	$tweet->{text} =~ s/\n/\\n/g;

	#($debug) && print STDERR "+++ Received tweet: " . $tweet->{text} . "(" . $tweet->{user}{screen_name} . ")\n";
	exit 0 if ($caught); # Signal received, exit smoothly
	my $i = 0;

	undef(%matches); 	# Reset the matching keywords/counters
	my $keyword;
	foreach $keyword (@keywordList) {
		my $count = 0;
		$count += () = $tweet->{text} =~ /$keyword/gi;
		if ($count > 0) {
			$matches{$i} = [ ( $keyword, $count ) ];
			$i++;
		}
	}
	if ($i) {
		# Generate the results based on matches
		my $buffer = "Found Tweet from \@" . $tweet->{user}{screen_name} . " : " . $tweet->{text} . " : ";
		my $key;
		for $key (keys %matches) {
			$buffer = $buffer . $matches{$key}[0] . " (" . $matches{$key}[1] . " times) ";
		}
		syslogOutput($buffer);
		#($cefDestination) && sendCEFEvent($tweet->{text});

	}
}

#
# Load the keywords to monitor from the configuration file
#
sub loadKeywordsFromFile {
	my $file = shift;
	die "A configuration file is required" unless defined($file);
	undef @keywordList; # Clean up array (if reloaded via SIGUSR1
	open(REGEX_FD, "$file") || die "Cannot open file $file";
	while(<REGEX_FD>) {
		chomp;
		(length > 0) && push(@keywordList, $_);
	}
	syslogOutput("Loaded " . @keywordList . " keywords from " . $file);
	return(1);
}


#
# Handle a proper process cleanup when a signal is received
#
sub sigHandler {
	syslogOutput("Received signal. Exiting.");
	unlink($pidFile) if (-r $pidFile);
	$caught = 1;
}

sub sigReload {
	syslogOutput("Reloading regular expressions");
	loadRegexFromFile($configfile);
	return;
}

#
# Send Syslog message using the defined facility
#
sub syslogOutput {
        my $msg = shift or return(0);
	if ($debug) {
		print STDERR "+++ $msg\n";
	}
	else {
		openlog($program, 'pid', $syslogFacility);
		syslog('info', '%s', $msg);
		closelog();
	}
}

#
# Send a CEF syslog packet to an ArcSight device/application
#
sub sendCEFEvent {
	my $pastie = shift;
	# Syslog data format must be "Jul 10 10:11:23"
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my @months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");
	my $timeStamp = sprintf("%3s %2d %02d:%02d:%02d", $months[$mon], $mday, $hour, $min, $sec);
	my $buffer = sprintf("<%d>%s CEF:0|%s|%s|%s|keyword-found|One or more keyword matched|%d|destinationDnsDomain=twitter.com msg=Interesting data has been found on twitter.com. ",
				29,
				$timeStamp,
				"blog.rootshell.be",
				$program,
				$version,
				$cefSeverity,
				$pastie
			);
	my $key;
	my $i = 1;
	for $key (keys %matches) {
		$buffer = $buffer . "cs" . $i . "=" . $matches{$key}[0] . " cs" . $i . "Label=Keyword". $i . "Name cn" . $i . "=" . $matches{$key}[1]. " cn" . $i . "Label=Keyword" . $i . "Count ";
		if (++$i > 6) {
			syslogOutput("Maximum 6 matching keyword can be logged");
			last;
		}
	}

	# Ready to send the packet!
	my $sock = new IO::Socket::INET(PeerAddr => $cefDestination,
					PeerPort => $cefPort,
					Proto => 'udp',
					Timeout => 1) or die 'Could not create socket: $!';
	$sock->send($buffer) or die "Send UDP packet error: $!";
}
