# Jabbot - Zabbot (Zabbix bot) plugin
# Copyright (C) 2010-2022 Fedor A. Fetisov <faf@ossg.ru>. All Rights Reserved
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Jabbot::Actions::Zabbot;

use strict;
use warnings;

use Jabbot::Service qw(log_it);

use JSON::RPC::Legacy::Client;
use JSON;

use POSIX;

use constant ZABBOT_VERSION => '0.4.0';

# About Zabbot
# Param: data hash (not used)
# Return: message about Zabbot
sub about {
    return "Zabbot v." . ZABBOT_VERSION .
". (c) 2010, 2011 Fedor A. Fetisov. Licensed under the terms of the GNU GPLv3.";
}

# Get some help
# Param: command name (optional)
# Return: help message
sub help {
    my $data = shift;
    my $type = undef;
# Check for incoming arguments: couldn't be more than 1
    if (scalar(@{$data->{'args'}}) > 1) {
	$type = 'help';
    }
    return _help($data, $type || $data->{'args'}->[0]);
}

# Get host info
# Param: data hash
# Return: message with information about host or error message
sub host {
    my $data = shift;

# Check for incoming arguments: should be at least one (hostname)
# and couldn't be more than 3
    unless (scalar(@{$data->{'args'}}) && scalar(@{$data->{'args'}}) < 4) {
	return _help($data, 'host');
    }

# Get hostname
    my $host = shift(@{$data->{'args'}});

# Get requested action (or set it to default one)
    my $action = shift(@{$data->{'args'}});
    $action ||= 'all';

# Check for remaining arguments
# (they could exist only if trigger info requested)
    if ( scalar(@{$data->{'args'}})
	    && (defined $action)
	    && ($action ne 'trigger') ) {

	return _help($data, 'host');

    }

# Check for unknown action
    if ( ($action ne 'all')
	    && ($action ne 'data')
	    && ($action ne 'trigger') ) {

	return _help($data, 'host');

    }

# Collect requested data and compose reply
    my $result = "\n";

    if ($action eq 'all') {
	$result .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("Data:\n");
    }

    if ($action eq 'all' || $action eq 'data') {
	$result .= show_items($host, $data);
    }

    if ($action eq 'all') {
	$result .= '-'x25 . "\n";
	$result .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("Triggers:\n");
    }

    if ($action eq 'all' || $action eq 'trigger') {
	$result .= show_triggers($host, $data);
    }

    return $result;
}

# Get Zabbix API version
# Param: data hash
# Return: Zabbix API version or error message
sub check_zabbix {
    my $data = shift;

# Check for absence of incoming arguments
    return _help($data, 'check-zabbix') if (scalar(@{$data->{'args'}}));

    my $object = {
		    'jsonrpc' => '2.0',
		    'method' => 'apiinfo.version',
		    'id' => 4,
		    'params' => {}
    };

    my $result = _json_request($data, $object);

    return $result->{'result'} if ($result->{'error'});

    return ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Connected to Zabbix with API version ')
		. $result->{'result'};
}


# Get all Zabbix items related to host
# Param: hostname
# Param: data hash
# Return: message with information about items or error message
sub show_items {
    my $host = shift;
    my $data = shift;

# Request all items
    my $object = {
		'jsonrpc' => '2.0',
		'method' => 'item.get',
		'auth' => ${$data->{'cache'}}->{'static'}->{'json'}->{'sid'},
		'id' => 2,
		'params' => {
		    'output' => 'extend',
		    'filter' => { 'host' => $host }
		}
    };

    my $result = _json_request($data, $object);

    return $result->{'result'} . "\n" if ($result->{'error'});

# Items successfully obtained, proceeding...
    my $string = '';
    foreach my $item (@{$result->{'result'}}) {
# Get all substitutes for placeholders in item description
	my @subst;
	if ($item->{'key_'} =~ /\[(.*)\]$/) {
	    foreach (split(/,/,$1)) {
		push (@subst, $_);
	    }
	}

# Replace all placeholders with substitutes
	if (scalar(@subst)) {
	    for (my $i=1; $i <= scalar(@subst); $i++) {
		$item->{'description'} =~ s/\$$i/$subst[$i-1]/g;
	    }
	}

# Transform item value into human-friendly format and compose item's string
	$string .= $item->{'description'} . ': '
		. _process_value(
		    $item->{'lastvalue'},
		    $item->{'units'},
		    ${$data->{'cache'}}->{'runtime'}->{'locale'})
		. "\n";
    }
    return $string ||
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('none') . "\n";
}

# Get all Zabbix triggers related to host
# Param: hostname
# Param: data hash
# Return: message with information about triggers or error message
sub show_triggers {
    my $host = shift;
    my $data = shift;

# Get requested mode (or set it to default one)
    my $mode = shift(@{$data->{'args'}});
    $mode ||= 'all';

# Check for unknown mode
    if ( ($mode ne 'all')
	    && ($mode ne 'warn')
	    && ($mode ne 'error') ) {

	return _help($data, 'host');

    }

# Request all triggers
    my $object = {
		'jsonrpc' => '2.0',
		'method' => 'trigger.get',
		'auth' => ${$data->{'cache'}}->{'static'}->{'json'}->{'sid'},
		'id' => 3,
		'params' => {
		    'output' => 'extend',
		    'filter' => { 'host' => $host }
		}
    };

    my $result = _json_request($data, $object);

    return $result->{'result'} if ($result->{'error'});

# Triggers successfully obtained, proceeding...
    my $string = '';
    foreach my $trigger (@{$result->{'result'}}) {
	my $temp = '';
	unless ($trigger->{'value'}) {
# Trigger's value '0' stands for fine state, don't place it in reply message
# 	unless all triggers requested
	    next unless ($mode eq 'all');
	    $temp .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("Ok\n");
	}
	elsif ($trigger->{'value'} == 1) {
	    $temp .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("Error!")
		. ($trigger->{'error'} ? ' (' . $trigger->{'error'} . ')' : '')
		. "\n";
	}
	elsif ($trigger->{'value'} == 2) {
# Trigger's value '2' stands for N/D state, don't place it in reply message
# 	if only errors requested
	    next if ($mode eq 'error');
	    $temp .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("N/D")
		. ($trigger->{'error'} ? ' (' . $trigger->{'error'} . ')' : '')
		. "\n";
	}
	else {
	    $temp .= ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale("Unknown state!\n");
	}
# Finally compose trigger's string
	$string .= $trigger->{'description'} . ': ' . $temp;
    }

    return $string ||
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('none');

}

# Get all Zabbix events for given host
# Param: data hash
# Return: message with information about events or error message
sub events {
    my $data = shift;

# Check for incoming arguments: should be at least one (hostname)
# and couldn't be more than 2
    unless (scalar(@{$data->{'args'}}) && scalar(@{$data->{'args'}}) < 3) {
	return _help($data, 'events');
    }

# Define number of events to output: if not specified (or invalid) - use default limit
    my $limit = ((defined $data->{'args'}->[1]) && ($data->{'args'}->[1] =~ /^\d+$/)) ?
		    $data->{'args'}->[1] :
		    $data->{'config'}->{'zabbix'}->{'default_events_limit'};

# Get events
    my $result = get_events($data, $limit, $data->{'args'}->[0]);

    return $result->{'result'} if ($result->{'error'});

# Events successfully obtained, proceeding...
    my $string = '';
    foreach my $event (@{$result->{'result'}}) {
	$string .= '[' .  _process_unixtime($event->{'lastchange'})
		    . '] ' . $event->{'description'} . "\n";
    }

    return $string ||
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('none');
}

# Get all Zabbix events
# Param: data hash
# Return: message with information about events or error message
sub all_events {
    my $data = shift;

# Check for incoming arguments: couldn't be more than 1
    unless (scalar(@{$data->{'args'}}) < 2) {
	return _help($data, 'all-events');
    }

# Define number of events to output: if not specified (or invalid) - use default limit
    my $limit = ((defined $data->{'args'}->[0]) && ($data->{'args'}->[0] =~ /^\d+$/)) ?
		    $data->{'args'}->[0] :
		    $data->{'config'}->{'zabbix'}->{'default_events_limit'};

# Get events
    my $result = get_events($data, $limit);

    return $result->{'result'} if ($result->{'error'});

# Events successfully obtained, proceeding...
    my $string = '';
    foreach my $event (@{$result->{'result'}}) {
	$string .= '[' .  _process_unixtime($event->{'lastchange'})
		    . '] ' . _escape_hostname($event->{'hosts'}->[0]->{'host'})
		    . ' : ' . $event->{'description'} . "\n";
    }

    return $string ||
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('none');

}

# Get events according to given params
# Param: data hash
# Param: number of events
# Param: hostname (optional)
sub get_events {
    my $data = shift;
    my $limit = shift;
    my $host = shift;

# Request all events sorted by time descendantly
    my $object = {
		'jsonrpc' => '2.0',
		'method' => 'trigger.get',
		'auth' => ${$data->{'cache'}}->{'static'}->{'json'}->{'sid'},
		'id' => 5,
		'params' => {
		    'output' => 'extend',
		    'select_hosts' => 'extend',
		    'limit' => $limit,
		    'sortorder' => 'DESC',
		    'sortfield' => 'lastchange'
		}
    };

# ... request events only for a given host if hostname specified
    $object->{'params'}->{'filter'} = { 'host' => $host } if (defined $host);

    return _json_request($data, $object);
}

# Get hosts list according to given params
# Param: data hash
# Return: message with list of hosts or error message
sub list_hosts {
    my $data = shift;

# Check for incoming arguments: should be at least one
    unless (scalar(@{$data->{'args'}})) {
	return _help($data, 'list-hosts');
    }

    my $object = {
		'jsonrpc' => '2.0',
		'method' => 'host.get',
		'auth' => ${$data->{'cache'}}->{'static'}->{'json'}->{'sid'},
		'id' => 6,
		'params' => {
		    'output' => 'extend',
		    'sortorder' => 'ASC',
		    'sortfield' => 'host'
		}
    };

# Advanced arguments check
    my $from = 0; # position of list limit statement in arguments array
    if ($data->{'args'}->[0] eq 'all') {
# Requested all hosts - check for unknown commands and limit value existance
# if limit command specified
	if (scalar(@{$data->{'args'}}) > 1) {
	    if ((scalar(@{$data->{'args'}}) < 3) || ($data->{'args'}->[1] ne 'limit')) {
		return _help($data, 'list-hosts');
	    }
	    else {
		$from = 2;
	    }
	}
    }
    else {

	my $with = 0; # flag for active 'with' command modifier
		      # (which is not allowed for all commands)

	for (my $i = 0; $i < scalar(@{$data->{'args'}}); $i++) {
	    if ($data->{'args'}->[$i] eq 'with') {
# Check for double 'with' command modifier
		return _help($data, 'list-hosts') if ($with);
		$with = 1;
		next;
	    }

# Limit command specified - store arguments array position and stop parsing commands
	    if ($data->{'args'}->[$i] eq 'limit') {
		$from = $i + 1;
		last;
	    }

	    if ($data->{'args'}->[$i] eq 'monitored') {
# Check for double 'monitored' command,
# also 'with' modifier for this command is forbidden - illegal syntax
		return _help($data, 'list-hosts')
		    if (($object->{'params'}->{'with_monitored_items'}) || $with);
		$object->{'params'}->{'with_monitored_items'} = 1;
	    }
	    else {
	    $with = 0;
		if ($data->{'args'}->[$i] eq 'triggers') {
# Check for double 'triggers' command
		    return _help($data, 'list-hosts')
			if ($object->{'params'}->{'with_monitored_triggers'});
		    $object->{'params'}->{'with_monitored_triggers'} = 1;
		}
		elsif ($data->{'args'}->[$i] eq 'http') {
# Check for double 'http' command
		    return _help($data, 'list-hosts')
			if ($object->{'params'}->{'with_monitored_httptests'});
		    $object->{'params'}->{'with_monitored_httptests'} = 1;
		}
		elsif ($data->{'args'}->[$i] eq 'data') {
# Check for double 'data' command
		    return _help($data, 'list-hosts')
			if ($object->{'params'}->{'with_historical_items'});
		    $object->{'params'}->{'with_historical_items'} = 1;
		}
		else {
# Unknown command
		    return _help($data, 'list-hosts');
		}
	    }
	}

# Opened 'with' command modifier - illegal syntax
	return _help($data, 'list-hosts') if ($with);

    }

# Define limit and offset if specified
    my $offset = 0;
    if ($from) {
	my $limit = '';
	for (my $i = $from; $i < scalar(@{$data->{'args'}}); $i++) {
	    $limit .= $data->{'args'}->[$i] . ' ';
	}
	chop($limit);
	unless ($limit =~ /^(\d+)\s?,?\s?(\d+)?$/) {
	    return _help($data, 'list-hosts');
	}
	else {
	    if ($2) {
# Since there are no offset param in host.get JSON method, have to get
# <limit + offset> entries and then just ignore first <offset> entries
		$object->{'params'}->{'limit'} = $2 + $1;
		$offset = $1;
	    }
	    else {
		$object->{'params'}->{'limit'} = $1;
	    }
	}
    }

# Get hosts
    my $result = _json_request($data, $object);

    return $result->{'result'} if ($result->{'error'});

# Hosts successfully obtained, proceeding...
    my $string = '';
    foreach my $host (@{$result->{'result'}}) {
# Ignore hosts in offset interval if it's specified
	if ($offset) {
	    $offset--;
	}
	else {
	    $string .= _escape_hostname($host->{'host'}) . "\n"
	}
    }

    return $string ||
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('none');

}

################################# Service functions #############################

# Initialize or restore JSON session
# Param: cache hash reference
# Param: configuration hash
# Return: hash with init result
#	hash format: {  error	=> <error code, 0 stands for OK>,
#			message => optional error description }
sub _init {
    my $cache = shift;
    my $config = shift;

    my $object;

# Create JSON client object if it doesn't already exist
    $$cache->{'runtime'}->{'json'}->{'client'} ||= new JSON::RPC::Legacy::Client;
    $$cache->{'runtime'}->{'json'}->{'client'}->version('1.0');

# Look for JSON session id in cache and check it if found
    if (defined $$cache->{'static'}->{'json'}->{'sid'}) {
	$object = {
		    'jsonrpc' => '2.0',
		    'method' => 'user.checkAuthentication',
		    'id' => 10,
		    'auth' => $$cache->{'static'}->{'json'}->{'sid'},
		    'params' => {
			'sessionid' => $$cache->{'static'}->{'json'}->{'sid'}
		    }
	};
	my $check = $$cache->{'runtime'}->{'json'}->{'client'}->call(
			$config->{'url'},
			$object
	);
# Connection failed
	unless ($check) {
	    return { 'error' => 2,
		     'message' => $$cache->{'runtime'}->{'json'}->{'client'}->status_line
	    };
	}

# Session id check failed - probably session expired, delete session id from cache
	delete $$cache->{'static'}->{'json'}->{'sid'} unless ($check->is_success);
    }

# Create new session if there are no valid session id
    unless (defined $$cache->{'static'}->{'json'}->{'sid'}) {
	$object = {
		'jsonrpc' => '2.0',
		'method' => 'user.login',
		'id' => 1,
		'params' => {
			    'username'	=> $config->{'username'},
			    'password'	=> $config->{'password'}
		}
	};

	my $result = $$cache->{'runtime'}->{'json'}->{'client'}->call(
			$config->{'url'},
			$object
	);

	if($result) {
	    if ($result->is_error) {
		return { 'error' => 1, 'message' => $result->error_message };
	    }
	    else {
		$$cache->{'static'}->{'json'}->{'sid'} = $result->result;
		return { 'error' => 0 };
	    }
	}
	else {
	    return {
		     'error' => 2,
		     'message' => $$cache->{'runtime'}->{'json'}->{'client'}->status_line
	    };
	}
    }

    return { 'error' => 0 };
}

# JSON request wrapper
# Param: hash with JSON request data
# Param: data hash
# Return: hash with JSON request result
#	hash format: { error => <1 on error, 0 on OK>,
#		       result => result object or error message }
sub _json_request {
    my $data = shift;
    my $object = shift;

# Initialize JSON connection
    my $init = _init($data->{'cache'}, $data->{'config'}->{'zabbix'});

    unless ($init->{'error'}) {

	my $result = ${$data->{'cache'}}->{'runtime'}->{'json'}->{'client'}->call(
			$data->{'config'}->{'zabbix'}->{'url'},
			$object
	);

	if($result) {
	    if ($result->is_error) {
		return { 'error' => 0,
			 'result' => ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Error: ')
			    . $result->{'code'} . ' ' . $result->{'message'} . ' ' . $result->{'data'} };
	    }
	    else {
		return { 'error' => 0,
			 'result' => $result->result };
	    }
	}
	else {
	    return { 'error' => 1,
		     'result' => ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Error. Got status line: ')
				    . ${$data->{'cache'}}->{'runtime'}->{'json'}->{'client'}->status_line };
	}
    }
    else {
	if ($init->{'error'} == 2) {
	    return { 'error' => 1,
		     'result' => ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Auth error in JSON client. Got status line: ')
				    . $init->{'message'} };
	}
	else {
	    return { 'error' => 1,
		     'result' => ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Auth error in JSON client: ')
				    . $init->{'message'} };
	}
    }

}

# Show help message
# Param: data hash
# Param: command to show help on (optional)
# Return: Zabbot usage message
sub _help {
    my $data = shift;
    my $type = shift;

    my $message = '';
    my $known = 0;
    my $separator = defined $type ? '' : "\n";

    if ((!defined $type) || ($type eq 'about')) {
	$message .= $separator . 'about';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'all-events')) {
	$message .= $separator . 'all-events [ <events-limit> ]';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'check-zabbix')) {
	$message .= $separator . 'check-zabbix';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'events')) {
	$message .= $separator . 'events <hostname> [ <count> ]';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'help-zabbot')) {
	$message .= $separator . 'help-zabbot [ <command-name> ]';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'host')) {
	$message .= $separator . 'host <hostname> [ all | data | trigger [all | warn | error ]';
	$known ||= 1;
    }
    if ((!defined $type) || ($type eq 'list-hosts')) {
	$message .= $separator . 'list-hosts [ all | [ monitored ] [ [ with ] triggers ] [ [ with ] http ] [ [ with ] data ] ] [ limit [ <offset>, ] <count> ]';
	$known ||= 1;
    }

    return $known ?
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Usage: ') . $message :
	    ${$data->{'cache'}}->{'runtime'}->{'locale'}->locale('Unknown command. Call \'help-zabbot\' for help on all commands.');
}

# Transform data from Zabbix into human-friendly format
# Param: data value
# Param: data units
# Param: localization object
# Return: transformed data value
sub _process_value {
    my $value = shift;
    my $units = shift;
    my $locale = shift;

# Data processors (by units)
    my $processors = {
	'B'	   => \&_process_bytes,
	'Bps'	   => \&_process_stream,
	'%'	   => \&_process_percents,
	'unixtime' => \&_process_unixtime,
	'uptime'   => \&_process_uptime
    };

# Skip transformation if data value isn't set or data units isn't set or
#	unknown (i.e. no processors available)
    return '' unless defined $value;
    return $value unless defined $units;
    return "$value $units" unless (defined $processors->{$units});



    return $processors->{$units}($value, $locale);
}

# Transform UNIX timestamp into human-friendly format
# Param: timestamp value
# Param: localization object (not used)
# Return: transformed timestamp
sub _process_unixtime {
    my $data = shift;
    return strftime("%Y-%m-%d %H:%M:%S", localtime($data));
}

# Transform storage volume into human-friendly format
# Param: volume value
# Param: localization object (not used)
# Return: transformed value
sub _process_bytes {
    my $data = shift;
    my @units = ('B', 'KB', 'MB', 'GB', 'TB');
    my $i = 0;
    while ( ($data >= 1024) && (defined $units[$i+1]) ) {
	$data = int($data / 1024 * 100 + 0.5) / 100;
	$i++;
    }

    return sprintf("%.2f %s", $data, $units[$i]);
}

# Transform percents value into human-friendly format
# Param: percents value
# Param: localization object (not used)
# Return: transformed value
sub _process_percents {
    my $data = shift;
    $data = int($data * 100 + 0.5) / 100;
    return sprintf("%.2f %%", $data);
}

# Transform bandwidth value into human-friendly format
# Param: bandwith value
# Param: localization object (not used)
# Return: transformed value
sub _process_stream {
    my $data = shift;
    my @units = ('Bps', 'KBps', 'MBps', 'GBps', 'TBps');
    my $i = 0;
    while ( ($data >= 1024) && (defined $units[$i+1]) ) {
	$data = int($data / 1024 * 100 + 0.5) / 100;
	$i++;
    }

    return sprintf("%.2f %s", $data, $units[$i]);
}

# Transform uptime in seconds into human-friendly format
# Param: uptime value
# Param: localization object
# Return: transformed uptime
sub _process_uptime {
    my $data = shift;
    my $locale = shift;
    my $result = '';

# Calculate full days
    if ($data > 86400) {
	my $days = int($data / 86400);
	$data -= $days * 86400;
	$result .= sprintf($locale->locale("%s days "), $days);
    }
# Calculate full hours
    if ($data > 3600) {
	my $hours = int($data / 3600);
	$data -= $hours * 3600;
	$result .= sprintf("%2d:", $hours);
    }
# Calculate full minutes
    if ($data > 60) {
	my $mins = int($data / 60);
	$data -= $mins * 60;
	$result .= sprintf("%2d:", $mins);
    }

    $result .= sprintf("%2d", $data);

    return $result;
}

# Escape double quotes and put hostname into double quotes if it contains spaces
# so one can then just copy and paste this hostname to use as an argument
# for 'host' command (for example)
# Param: hostname
# Return: escaped hostname
sub _escape_hostname {
    my $hostname = shift;

    $hostname =~ s/\"/\\\"/;
    if ($hostname =~ /\s/) {
	$hostname = '"' . $hostname . '"';
    }

    return $hostname;
}

1;
