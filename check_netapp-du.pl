#!/usr/bin/perl -w
#
# Nagios plugin to report disk space and number of files in a NetApp file share
# Copyright (c) 2009 Rob Hassing and Peter Mc Aulay
#
# Thanks to Frederic De Wilde, Jean-Francois Peyridieu and Toni Garcia-Navarro
# for their assistance in adding support for 64 bit counters.
#
# Last updated 2017-02-13 by Peter Mc Aulay
#

use strict;
use lib "/usr/lib/nagios/plugins";
use lib "/usr/lib64/nagios/plugins";
use lib "/usr/local/nagios/libexec";
use Getopt::Long qw(:config no_ignore_case);
use utils qw(%ERRORS);

# Path to manual CIFS to volume/qtree map file
my $MAPFILE = "/usr/lib/nagios/plugins/netapp-shares.map";

# Path to NetApp MIB table (get it from http://www.protocolsoftware.com/documents/mibs/netapp.mib.txt)
my $MIBFILE = "/usr/share/snmp/mibs/NETWORK-APPLIANCE-MIB.txt";

# Path to cache files
my $CACHEPATH = "/tmp";
# Filename prefix for cache files
my $CACHEFILE = ".netapp-oidcache";

# Default NetApp volume name prefix
my $prefix = "/vol";

#
# Configuration ends ###
#

my $PROGNAME = "check_netapp-du.pl";
my $REVISION = "2.4.4";

# Pre-declare functions
sub usage;
sub print_help();
sub print_version();
sub find_share_in_cache();

# Initialise some variables
my ($version, $help, $vol, $host, $forcegencache);
my ($nr, $ShareType, $dfBT, $dfBU, $dfBTI, $dfBUI, $dfMF, $dfUF, $dfBP, $dfMP);
my $warning = 0;
my $critical = 0;
my $files_warn = 0;
my $files_crit = 0;
my $snmpgetcmd;
my @result;
my @stats;

# Defaults
my $exact = 0;
my $debug = 0;
my $snmp_comm = "public";

#
# Get input
#
Getopt::Long::Configure('no_ignore_case');
GetOptions(
	"V|version"		=> \$version,
	"h|help"		=> \$help,
	"w|warning=s"		=> \$warning,
	"c|critical=s"		=> \$critical,
	"f|files-warn=i"	=> \$files_warn,
	"F|files-crit=i"	=> \$files_crit,
	"H|hostname=s"		=> \$host,
	"v|volume=s"		=> \$vol,
	"C|community=s"		=> \$snmp_comm,
	"force-gencache"	=> \$forcegencache,
	"e|exact"		=> \$exact,
	"prefix=s"		=> \$prefix,
	"debug"			=> \$debug,
);

($help) && print_help();
($version) && print_version();

# Some debug output
if ($debug) {
	print "DEBUG: $PROGNAME $REVISION starting\n";
	print "DEBUG: Using MIB definitions from $MIBFILE\n";
	print "DEBUG: Using local map $MAPFILE\n";
	print "DEBUG: Using cache path $CACHEPATH\n";
}

#
# Input validation
#

($host) || usage("Hostname is mandatory");
($vol) || usage("Volume not specified");

# Normalise hostname
$host = $1 if ($host =~ /([-.A-Za-z0-9]+)/);
($host) || usage("Invalid hostname");

# Normalise share name, or not if the user is sure
$vol =~ s/^\/$prefix\///g unless $exact;
# Nagios doubles dollar signs during macro expansion
$vol =~ s/\$\$/\$/g;
($vol) || usage("Invalid volume");

# Normalise thresholds
$files_crit = 0 if not $files_crit;
$files_warn = $files_crit if not $files_warn;
$warning = $critical if not $warning;
$warning = $1 if ($warning && $warning =~ /([0-9.]+)+/);
$critical = $1 if ($critical && $critical =~ /([0-9.]+)+/);

# Strip path separators from prefix
$prefix =~ s/\///g;

# Resolve hostname to IP address to account for DNS aliases, etc.
my @hostdata = gethostbyname($host);
(@hostdata) || usage("Host not found: $host");
my @ipaddr = unpack("C4",$hostdata[4]);
my $IP = join(".", @ipaddr);

#
# Select which set of SNMP OIDs to use
#

# Detect ONTAP version
my ($oid_get_qtree_stats, $oid_get_volume_stats, $oid_get_parent_volume_oid, $oid_get_volume_name);
$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.789.1.1.2.0\"";
@result = `$snmpgetcmd`;
chomp(@result);
$result[0] =~ /NetApp Release (.*?):/;
my $productVersion = $1;
my $counter_size;

# ONTAP 7.x or 8.x in "7-Mode"
if ($productVersion =~ /^7\./ or $productVersion =~ /7-Mode/) {
	$counter_size = 32;
	# Get size and usage:
	# qrV2HighKBytesUsed, qrV2LowKBytesUsed, qrV2HighKBytesLimit, qrV2LowKBytesLimit, qrV2FilesUsed, qrV2FileLimit
	$oid_get_qtree_stats="789.1.4.6.1.{4,5,7,8,9,11}";
	# dfHighKBytesUsed, dfLowKBytesUsed, dfHighTotalKBytes, dfLowTotalKBytes, dfMaxFilesUsed, dfMaxFilesAvail
	$oid_get_volume_stats="789.1.5.4.1.{16,17,14,15,12,11}";

# ONTAP 8.x C-Mode filers use different OIDs and 64 bit size counters
} elsif ($productVersion =~ /^8\./) {
	$counter_size = 64;
	# Get size and usage:
	# qrV264KBytesUsed, qrV264KBytesLimit, qrV2FilesUsed, qrV2FileLimit
	$oid_get_qtree_stats="789.1.4.6.1.{25,26,9,11}";
	# df64UsedKBytes, df64TotalKBytes, dfMaxFilesUsed, dfMaxFilesAvail
	$oid_get_volume_stats="789.1.5.4.1.{30,29,12,11}";

} else {
	print "Sorry, I can only talk to NetApp Release 7 or 8 filers (not $productVersion).\n";
	exit $ERRORS{'UNKNOWN'};
}

# Common OIDs
#
# Look up parent volume OID (qrV2Volume)
$oid_get_parent_volume_oid="789.1.4.6.1.13";
# Look up parent volume name (qvStateName)
$oid_get_volume_name="789.1.4.4.1.2";

#
# Use a local cache for mapping shares to OIDs, as this is relatively static.
# Retrieving a full inventory from the NAS every time is much too slow.
#

# Every host has a cache file containing an inventory of its volumes and qtrees.
# This file is used to do OID lookups since it's much faster than asking the
# NetAPP filer to dump its entire inventory on every check.
my $cache = "$CACHEPATH/$CACHEFILE.$IP";

# If cache file exists and is not empty, use it
if (-f $cache && (stat(_))[7] != 0 && not $forcegencache) {
	print "DEBUG: Cache found: $cache\n" if $debug;
# Cache files should be refreshed regularly, because NetApp renumbers objects
# during normal use, when adding or removing shares or snapshots
} else {
	print "DEBUG: No cache file or cache regeneration forced\n" if $debug;

	# One cache update at a time - though a lock held for more than an hour is considered stale
	# Note: if retrieving the share inventory takes longer than the Nagios plugin time-out, the
	# process will be killed - so you may want to pre-generate the caches via cron.
	if (-f "$cache.lock" && (stat("$cache.lock"))[9] > (time - 3600)) {
		print "Cache update in progress, please try again later\n";
		exit $ERRORS{'UNKNOWN'};
	} else {
		open(LOCKFILE, ">", "$cache.lock") or die("Cannot create lock file: $!");
		print LOCKFILE $$;
		close LOCKFILE;
	}

	# Volume auto-discovery & cache generation
	# NetApp shares can be either QTrees or Volumes
	# Skip snapshots
	system("/usr/bin/snmptable -v 2c -c $snmp_comm -C iHf \: -m $MIBFILE $host NETAPP-MIB\:\:qrV2Table|grep qrV2TypeTree|awk -F\: '{print \"QTree\:\" \$1 \"\:\\\"\" \$13\"\\\"\"}' > $cache");
	if ($? != 0) {
		unlink <$cache.lock>;
		print "CRITICAL - Could not cache list of shares: error " . ($? >> 8) . "\n";
		exit $ERRORS{'CRITICAL'};
	}
	system("/usr/bin/snmptable -v 2c -c $snmp_comm -C iHf \: -m $MIBFILE $host NETAPP-MIB\:\:dfTable|grep mounted|grep -v \.snapshot|awk -F\: '{print \"Volume\:\" \$1 \"\:\\\"\" \$3\"\\\"\"}' >> $cache");
	if ($? != 0) {
		unlink <$cache.lock>;
		print "CRITICAL - Could not cache list of volumes: error " . ($? >> 8) . "\n";
		exit $ERRORS{'CRITICAL'};
	}
	unlink <$cache.lock>;
}

#
# Read volume index from cache
# FIXME: turn this into a sub?
#
print "DEBUG: Finding $vol in $cache\n" if $debug;

# CIFS shares don't map to volumes or qtrees exactly, so we need to apply some heuristics
my $match = $vol;
my $found;
$ShareType = "";
$nr = "";

# Note: from here on we look for $match, not $vol

# First check for an explicit share to path mapping
if (-f $MAPFILE) {
	open(MAPFILE, $MAPFILE) or die "Failed to open file $MAPFILE: $!\n";
	while (my $line = <MAPFILE>) {
		# Skip comments and empty lines
		next if $line =~ /^#/;
		next if $line =~ /^\s+$/;
		my @fields = split(/:/, $line);
		if ($fields[0] eq $host and $fields[1] eq $vol) {
			chomp $fields[2];
			if ($fields[2] ne "") {
				$match = $fields[2];
				$exact = 1;
				print "DEBUG: Found local mapping to $match.\n" if $debug;
			} else {
				print "DEBUG: Local mapping found but invalid\n" if $debug;
			}
		}
	}
	close MAPFILE;
} else {
	print "DEBUG: Not using any static share mappings\n" if $debug;
}

# Assume the user knows what they're doing when specifying a full NFS/NetApp path
$exact = 1 if $match =~ /^\/$prefix/;

print "DEBUG: Exact match, disabling heuristics\n" if ($exact && $debug);

unless ($exact) {
	# For subdirectories of QTrees we consider the parent QTree only
	# TODO: this is a dirty hack.  The proper solution is, if the path is not found in the cache,
	# to strip the last path component and re-run the search (see FIXME above)
	my $pathdepth = 0;
	my @pathspec = split("/", $match);
	foreach (@pathspec) {
		next if /^$/;
		next if $_ eq $prefix;
		$pathdepth++;
		if ($pathdepth > 2) {
			print "DEBUG: path too deep: $_\n" if $debug;
			$match =~ s/\/$_.*//g;
			next;
		} else {
			print "DEBUG: descending into $_ depth $pathdepth\n" if $debug;
		}
	}
	# /TODO

	# Some common substitutions for better search accuracy
	$match =~ s/^CA_//g;
	$match =~ s/r\$$//g;
	$match =~ s/_share$//g;
	# Underscores, caps and numbers often indicate a path separator but the parts may be incomplete
	$match =~ s/_/.*_/g;
	$match =~ s/([A-Z])/.*$1/g;
	$match =~ s/([0-9])/.*$1/g;
	# Replace non-alphanumerics with wildcards
	$match =~ s/[^a-zA-Z0-9+*]/\./g;
}

print "DEBUG: Final regexp pattern: $match\n" if $debug;

# Read through file and match as exactly as possible
# Keep trying until we get an exact-ish match or the file ends
open(FILE, $cache) or die "Failed to open file $cache: $!\n";
while(my $line = <FILE>) {
	my @fields;
	# Strip duplicate quotes (added by some MIB versions)
	$line =~ s/""/"/g;
	#
	# Is it a volume?
	#
	if ($line =~ m{Volume:.*:"$vol"$}i) {
		@fields = split(/:/, $line);
		$nr = $fields[1];
		$found = $fields[2];
		chomp($found);
		$ShareType = "Volume";
		print "DEBUG: Exact volume match found with ID $nr\n" if $debug;
		last;
	} elsif ($line =~ m{Volume:.*:"$match/?"}i) {
		@fields = split(/:/, $line);
		$nr = $fields[1];
		$found = $fields[2];
		chomp($found);
		$ShareType = "Volume";
		print "DEBUG: Near-exact volume match found with ID $nr\n" if $debug;
		last;
	} elsif ($line =~ m{Volume:.*:"/$prefix/v_$match/"}i and not $exact) {
		@fields = split(/:/, $line);
		$nr = $fields[1];
		$found = $fields[2];
		chomp($found);
		$ShareType = "Volume";
		print "DEBUG: Close volume match found with ID $nr\n" if $debug;
		last;
	} elsif ($line =~ m{Volume:.*$match}i and not $exact) {
		@fields = split(/:/, $line);
		$nr = $fields[1];
		$found = $fields[2];
		chomp($found);
		$ShareType = "Volume";
		print "DEBUG: Sloppy volume match found with ID $nr\n" if $debug;
	} else {
		#
		# Is it a QTree?
		#
		if ($line =~ m{QTree:.*:"$vol"$}i) {
			@fields = split(/:/, $line);
			$nr = $fields[1];
			$found = $fields[2];
			chomp($found);
			$ShareType = "QTree";
			print "DEBUG: Exact qtree match found with ID $nr\n" if $debug;
			last;
		} elsif ($line =~ m{QTree:.*:"$match"}i) {
			@fields = split(/:/, $line);
			$nr = $fields[1];
			$found = $fields[2];
			chomp($found);
			$ShareType = "QTree";
			print "DEBUG: Near-exact qtree match found with ID $nr\n" if $debug;
			last;
		} elsif ($line =~ m{QTree:.*:"$prefix/v_$match"}i and not $exact) {
			@fields = split(/:/, $line);
			$nr = $fields[1];
			$found = $fields[2];
			chomp($found);
			$ShareType = "QTree";
			print "DEBUG: Close qtree match found with ID $nr\n" if $debug;
			last;
		} elsif ($line =~ m{QTree:.*$match}i and not $exact) {
			@fields = split(/:/, $line);
			$nr = $fields[1];
			$found = $fields[2];
			chomp($found);
			$ShareType = "QTree";
			print "DEBUG: Sloppy qtree match found with ID $nr\n" if $debug;
		}
	}
}
close FILE;

# Give up if nothing matches at all
if ($nr eq "") {
	print "UNKNOWN - $vol not found in Volume or QTree list\n";
	exit $ERRORS{'UNKNOWN'};
}

# /FIXME

print "DEBUG: Found: $vol ($found) is a $ShareType and has ID $nr\n" if $debug;

#
# Get file share's usage statistics
#

# Retrieved values
my ($dfHighKBytesUsed, $dfLowKBytesUsed, $dfHighTotalKBytes, $dfLowTotalKBytes);
my ($dfMaxFilesUsed, $dfMaxFilesAvail);
my ($qrV2QuotaUnlimited, $qrV2FileQuotaUnlimited);
my ($qrV264KBytesUsed, $qrV264KBytesLimit, $df64UsedKBytes, $df64TotalKBytes);

# Derived values
my ($dfKBytesUsed, $dfGBytesUsed, $dfKBytesTotal, $dfGBytesTotal, $dfPctUsed);
my ($dfFilesMax, $dfFilesUsed, $dfPctFiles);

# Construct command line - get the same data for all types, in the same order
if ($ShareType eq "QTree") {
	$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.$oid_get_qtree_stats.$nr\"";
} elsif ($ShareType eq "Volume") {
	$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.$oid_get_volume_stats.$nr\"";
}

# Execute
@stats = `$snmpgetcmd`;
chomp(@stats);
unless ($stats[0] =~ /\d+/) {
	print "Error during SNMP GET: ";
	if ($stats[0] eq 'No Such Instance currently exists at this OID') {
		print "Object ID $nr does not exist (cache out of date?)";
	} else {
		print "Cannot connect to NAS: " . $stats[0];
	}
	print "\n";
	exit $ERRORS{'UNKNOWN'};
}

# 64 bit counters can be used directly
if ($counter_size == 64) {
	# Despite the name, these counters return bytes for QTrees (this may be a bug)
	if ($ShareType eq "QTree") {
		$dfKBytesUsed = $stats[0] / 1024;
		$dfKBytesTotal = $stats[1] / 1024;
	} else {
		$dfKBytesUsed = $stats[0];
		$dfKBytesTotal = $stats[1];
	}
	$dfMaxFilesUsed = $stats[2];
	$dfMaxFilesAvail = $stats[3];

	print "DEBUG: Raw stats retrieved (64 bit): dfKBytesUsed=$dfKBytesUsed dfKBytesTotal=$dfKBytesTotal dfMaxFilesUsed=$dfMaxFilesUsed dfMaxFilesAvail=$dfMaxFilesAvail\n" if $debug;

# 32 bit counters require some assembling
} else {
	$dfHighKBytesUsed = $stats[0];
	$dfLowKBytesUsed = $stats[1];
	$dfHighTotalKBytes = $stats[2];
	$dfLowTotalKBytes = $stats[3];
	$dfMaxFilesUsed = $stats[4];
	$dfMaxFilesAvail = $stats[5];

	print "DEBUG: Raw stats retrieved: HighKBUsed=$dfHighKBytesUsed LowKBUsed=$dfLowKBytesUsed HighKBTotal=$dfHighTotalKBytes LowKBTotal=$dfLowTotalKBytes FilesUsed=$dfMaxFilesUsed FilesMax=$dfMaxFilesAvail\n" if $debug;

	# Disk space stats are split into two values: most and least significant 32 bits of a 64 bit unsigned integer
	# (SNMPv1/2 only support 32 bit values and this is not enough for volumes >2TB)
	#
	# From https://communities.netapp.com/thread/1305:
	# if (Low >= 0) x = High * 2^32 + Low
	# if (Low < 0)  x = (High + 1) * 2^32 + Low
	$dfKBytesUsed = ($dfHighKBytesUsed * 2**32 + $dfLowKBytesUsed) if $dfLowKBytesUsed >= 0;
	$dfKBytesUsed = (($dfHighKBytesUsed + 1) * 2**32 + $dfLowKBytesUsed) if $dfLowKBytesUsed < 0;
	$dfKBytesTotal = ($dfHighTotalKBytes * 2**32 + $dfLowTotalKBytes) if $dfLowTotalKBytes >= 0;
	$dfKBytesTotal = (($dfHighTotalKBytes + 1) * 2**32 + $dfLowTotalKBytes) if $dfLowTotalKBytes < 0;
}

# Check that the QTrees has valid quota defined, otherwise use the parent volume for max size and file limit values
my $hasQuota = 1;
my ($RealKBytesTotal, $RealKBytesUsed, $RealMaxFilesUsed, $RealFilesAvail, $RealHighKBytesUsed, $RealLowKBytesUsed, $RealKBFree);
if ($ShareType eq "QTree") {
	# Get parent volume OID
	$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.$oid_get_parent_volume_oid.$nr\"";
	@result = `$snmpgetcmd`;
	chomp(@result);
	my $qrV2Volume = $result[0];

	# Get parent volume name
	$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.$oid_get_volume_name.$qrV2Volume\"";
	@result = `$snmpgetcmd`;
	chomp(@result);
	my $qvStateName = $result[0];
	$qvStateName =~ s/"//g;

	print "DEBUG: QTree's parent volume /$prefix/$qvStateName has OID $qrV2Volume\n" if $debug;

	# Finally, get volume stats of parent volume
	$snmpgetcmd = "/bin/bash -c \"/usr/bin/snmpget -v 2c -Cf -OvqU -c $snmp_comm $IP SNMPv2-SMI::enterprises.$oid_get_volume_stats.$qrV2Volume\"";
	@stats = `$snmpgetcmd`;
	chomp(@stats);
	unless ($stats[0] =~ /\d+/) {
		print "Error during SNMP GET: ";
		if ($stats[0] eq 'No Such Instance currently exists at this OID') {
			print "Object ID $qrV2Volume does not exist (cache out of date?)";
		} else {
			print "Cannot connect to NAS: " . $stats[0];
		}
		print "\n";
		exit $ERRORS{'UNKNOWN'};
	}

	# 64 bit counters can be used directly
	if ($counter_size == 64) {
		$RealKBytesUsed = $stats[0];
		$RealKBytesTotal = $stats[1];
		$RealMaxFilesUsed = $stats[2];
		$RealFilesAvail = $stats[3];

		print "DEBUG: Raw stats retrieved (64 bit): dfKBytesUsed=$RealKBytesUsed dfKBytesTotal=$RealKBytesTotal dfMaxFilesUsed=$RealMaxFilesUsed dfMaxFilesAvail=$RealFilesAvail\n" if $debug;
	# 32 bit counters require some assembling
	} else {
		$dfHighKBytesUsed = $stats[0];
		$dfLowKBytesUsed = $stats[1];
		$dfHighTotalKBytes = $stats[2];
		$dfLowTotalKBytes = $stats[3];
		$dfMaxFilesUsed = $stats[4];
		$dfMaxFilesAvail = $stats[5];

		print "DEBUG: Raw volume stats retrieved: dfHighTotalKBytes=$dfHighTotalKBytes dfLowTotalKBytes=$dfLowTotalKBytes dfMaxFilesAvail=$RealFilesAvail dfHighKBytesUsed=$RealHighKBytesUsed dfLowKBytesUsed=$RealLowKBytesUsed\n" if $debug;

		# Calculate totals
		$RealKBytesTotal = ($dfHighTotalKBytes * 2**32 + $dfLowTotalKBytes) if $dfLowTotalKBytes >= 0;
		$RealKBytesTotal = (($dfHighTotalKBytes + 1) * 2**32 + $dfLowTotalKBytes) if $dfLowTotalKBytes < 0;
		$RealKBytesUsed = ($RealHighKBytesUsed * 2**32 + $RealLowKBytesUsed) if $RealLowKBytesUsed >= 0;
		$RealKBytesUsed = (($RealHighKBytesUsed +1) * 2**32 + $RealLowKBytesUsed) if $RealLowKBytesUsed < 0;
	}

	$RealKBFree = $RealKBytesTotal - $RealKBytesUsed;

	print "DEBUG: Raw volume usage = $RealKBytesUsed KB used of $RealKBytesTotal, $RealKBFree KB free\n" if $debug;
	print "DEBUG: Max quota for this QTree = $dfKBytesTotal\n" if $debug;

	# Use volume's total size if no qtree quota limit defined
	if ($dfKBytesTotal eq 0) {
		print "DEBUG: No usage quota, taking max total size from volume\n" if $debug;
		$dfKBytesTotal = $RealKBytesTotal;
		$hasQuota = 0;
	}

	# Use volume's max files if not defined on qtree level
	if ($dfMaxFilesAvail eq 0) {
		print "DEBUG: No file quota, taking max files from volume\n" if $debug;
		$dfMaxFilesAvail = $RealFilesAvail;
	}
}

# Round off our derived values
print "DEBUG: KB used: $dfKBytesUsed, KB total: $dfKBytesTotal\n" if $debug;
$dfGBytesUsed = sprintf("%.2f", ($dfKBytesUsed / 1024 / 1024));
$dfGBytesTotal = sprintf("%.2f", ($dfKBytesTotal / 1024 / 1024));

$dfFilesUsed = sprintf("%.0f", $dfMaxFilesUsed);
$dfFilesMax = sprintf("%.0f", $dfMaxFilesAvail);
print "DEBUG: Files used: $dfFilesUsed, max: $dfFilesMax\n" if $debug;

# Derive percentages
$dfPctUsed = $dfKBytesUsed / $dfKBytesTotal * 100;
$dfPctFiles = $dfFilesUsed / $dfFilesMax * 100;
# Round off percentages
$dfPctUsed = sprintf("%.2f", $dfPctUsed);
$dfPctFiles = sprintf("%.2f", $dfPctFiles);

#
# Check against the provided thresholds and set the appropriate status
#

print "DEBUG: Checking against thresholds: w=$warning c=$critical fw=$files_warn fc=$files_crit\n" if $debug;

my $status;
my $rc;

# Catch "Qtree's underlying volume full" condition
if ($RealKBFree && $RealKBFree <= 0) {
	$status = "CRITICAL - VOLUME FULL";
	$rc = $ERRORS{'CRITICAL'};
# Disk space critical
} elsif ($critical && $dfPctUsed > $critical) {
	$status = "CRITICAL";
	$rc = $ERRORS{'CRITICAL'};

# Disk space warning
} elsif ($warning && $dfPctUsed > $warning) {
	$status = "WARNING";
	$rc = $ERRORS{'WARNING'};

# Files critical
} elsif ($files_crit && $dfFilesUsed > $files_crit) {
	$status = "FILES CRITICAL";
	$rc = $ERRORS{'CRITICAL'};

# Files warning
} elsif ($files_warn && $dfFilesUsed > $files_warn) {
	$status = "FILES WARNING";
	$rc = $ERRORS{'WARNING'};

# Everything OK
} else {
	$status = "OK";
	$rc = $ERRORS{'OK'};
}


#
# Report & exit
#
print "$status - ", $debug ? "$ShareType " : "", $vol, $debug ? " ($found)" : "", " usage: $dfGBytesUsed / $dfGBytesTotal GB", $hasQuota ? "" : " (volume limit, no quota)", " ($dfPctUsed% full), $dfFilesUsed / $dfFilesMax files ($dfPctFiles%)|used=", $dfKBytesUsed , "KB;", $warning ? ($warning * $dfKBytesTotal / 100) : "" ,";", $critical ? ($critical * $dfKBytesTotal / 100) : "" ,";0;",$dfKBytesTotal," used_pct=$dfPctUsed%;", $warning ? $warning : "" ,";", $critical ? $critical : "" ,";0;100 files=$dfFilesUsed;", $files_warn ? ($files_warn * $dfFilesMax) : "" ,";", $files_crit ? ($files_crit * $dfFilesMax) : "" ,";0;$dfFilesMax files_pct=$dfPctFiles%;", $files_warn ? $files_warn : "" ,";", $files_crit ? $files_crit : "" ,";0;100\n";
exit $rc;

### Main programme ends ###

#
# Functions
#

# Stub for future use
sub find_share_in_cache() {
	return 0;
}

# Die with usage info, for improper invocation
sub usage {
	my $format = shift;
	printf($format, @_);
	print "\n";
	print "Use --help for detailed instructions.\n";
	exit $ERRORS{'UNKNOWN'};
}

# Print version and exit
sub print_version() {
	print "This is $PROGNAME version $REVISION\n";
	exit $ERRORS{'OK'};
}

# Command line help
sub print_help() {
	print "This is $PROGNAME version $REVISION\n";
	print qq|Copyright (c) 2009 Rob Hassing, 2012-2014 Peter Mc Aulay

This plugin reports the usage of a NetApp storage volume.

Usage: $PROGNAME -H <host> -v <volume> [-C community] -w <warn> -c <crit> [-e] [-f files-warn] [-F files-crit] [--force-gencache] [--prefix=/vol] [--debug]

-H, --hostname=HOST
   Name or IP address of host to check
-v, --volume=Volume
   Name of the Volume, QTree or CIFS share to check
-e, --exact
   Assume Volume is an exact NetApp path, don't try to fuzzy match
-C, --community=community
   SNMP read community (default "public")
-w, --warning=X
   Percentage above which a WARNING status will result
-c, --critical=X
   Percentage above which a CRITICAL status will result
-f, --files-warn=X
   Return WARNING if more than X files in volume
-F, --files-crit=X
   Return CRITICAL if more than X files in volume
--prefix=PREFIX
   Assume NetApp paths start with PREFIX, by default "/vol"
--force-gencache
   Force cache file generation (slow, don't use from Nagios)
--debug
   Show lots of debug messages
-V, --version
   Display program version

Support information:

Send email to pmcaulay\@evilgeek.net if you have questions regarding use of this
software, or to submit patches or suggest improvements.  Please include version
information with all correspondence (the output of the --version option).

This Nagios plugin comes with ABSOLUTELY NO WARRANTY. You may redistribute
copies of the plugins under the terms of the GNU General Public License.
For more information about these matters, see the file named COPYING.

|;
	exit $ERRORS{'OK'};
}

