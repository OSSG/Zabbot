#!/usr/bin/perl -w
# Jabbot - core script
# Copyright (C) 2010 Fedor A. Fetisov <faf@ossg.ru>. All Rights Reserved
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

use strict;
use warnings;

use Data::Dumper;
use Encode qw(_utf8_on _utf8_off);
use Getopt::Long qw(:config no_ignore_case bundling no_auto_abbrev);
use IO::Socket::SSL;
use Net::Jabber;
use POSIX;

use FindBin;
use lib $FindBin::Bin;

use Jabbot::Service qw(format_string write_to_file log_it);
use Jabbot::Locale;

chdir($FindBin::Bin);

my $options = {};

GetOptions(
    $options, 'help|?', 'config=s', 'debug|d'
) or die "For usage information try: \t$0 --help\n";

if ($options->{'help'}) {
    print <<HELP
Jabbot (Jabber bot) script
Usage: $0 [options] [--config=<file> | --help]
Options:
	    --debug|-d	- run Jabbot in foreground
HELP
;
    exit;
}
# Get configuration
my $config = do($options->{'config'} || './config');
if ($@) {
    print STDERR "Bad configuration format: $@\n";
    exit 1;
}
unless ($config) {
    print STDERR "Configuration not found!\n";
    exit 1;
}

my $cache = { 'static' => {}, 'runtime' => {} };

# Try to restore static part of cache from the previous run
if (-f $config->{'cache'}) {
    $cache->{'static'} = do($config->{'cache'});
    if ($@) {
	print STDERR "Error while restoring cache: $@\n";
    }
}

# Set function for processing unknown commands
# (If such function isn't defined in config then empty one will be used)
if (defined $config->{'errors'}->{'not_found_func'}) {
    my ($module, $func) = split('/', $config->{'errors'}->{'not_found_func'});
    eval "require $module";
# Check for errors on module connection
    unless($@) {
	*not_found = $module . '::' . $func;
    }
} else {
    *not_found = \&empty;
}

# Set function for processing forbidden commands
# (If such function isn't defined in config then empty one will be used)
if (defined $config->{'errors'}->{'forbidden_func'}) {
    my ($module, $func) = split('/', $config->{'errors'}->{'forbidden_func'});
    eval "require $module";
# Check for errors on module connection
    unless(@$) {
	*forbidden = $module . '::' . $func;
    }
} else {
    *forbidden = \&empty;
}

# Set function for processing commands failed due to some error in external module or function
# (If such function isn't defined in config then empty one will be used)
if (defined $config->{'errors'}->{'fail_func'}) {
    my ($module, $func) = split('/', $config->{'errors'}->{'fail_func'});
    eval "require $module";
    unless(@$) {
# Check for errors on module connection
	*fail = $module . '::' . $func;
    }
} else {
    *fail = \&empty;
}

# Go into background mode unless debug flag is set on
unless ($options->{'debug'}) {
    exit if fork;
}

# Open and lock log file
unless (open(LOG, '>>' . $config->{'log'})) {
    print STDERR "Can't open log file " . $config->{'log'} . " for write: $!\n";
    exit 1;
}
unless (flock(LOG, 2)) {
    print STDERR "Can't lock log file " . $config->{'log'} . ": $!\n";
    exit 1;
}

# Reroute output to log file
select(LOG);
# Turn output buffering off
$| = 1;

# Log start
log_it('Jabbot core: I live, again!');

# Initialize locale object
$cache->{'runtime'}->{'locale'} = Jabbot::Locale->new($config->{'locale'});

my $client;

my $die_flag = $config->{'reconnect'} ? 0 : 1;

# External working loop - connect and reconnect until 'die flag' will be set
do {

# Initialize Jabber-client
    $client = new Net::Jabber::Client( debuglevel => $options->{'debug'});

# Set callbacks for service actions: authorization and disconnection
    $client->SetCallBacks( onauth => \&onAuth, ondisconnect => \&onDisconnect, message => \&messageCB );

# Go into the main working loop
    $client->Execute(%{$config->{'connection'}});

# Disconnect
    $client->Disconnect();

# Log an attempt to create new connection (if jabbot should do so)
    log_it('Jabbot core: Try to connect once more...') unless ($die_flag);

}while(!$die_flag);

log_it('Jabbot core: Died');

exit;

################################# Core functions ################################

# Authorization reaction: send online presence
# Param: none
# Return: none
sub onAuth {
    $client->PresenceSend(type=>'available', priority=>10);
    return;
}

# Disconnection reaction: if 'die flag' is set on then 'die' for real
# Param: none
# Return: none
sub onDisconnect {
    if ($die_flag) {
# log death moment
	log_it('Jabbot core/onDisconnect: I die, again...');
	exit;
    }
    return;
}

# Reaction on message
# Param: session id
# Param: message
# Return: none
sub messageCB {
    my $sid = shift;
    my $message = shift;
    my $type = $message->GetType();
    if ('chat' eq $type) {
        return messageChatCB($sid, $message);
    }
    elsif ('normal' eq $type) {
        return messageNormalCB($sid, $message);
    }
    elsif ('groupchat' eq $type) {
        return messageNormalCB($sid, $message);
    }
    else {
        log_it('Got unknown message of type ' . $type);
    }
}

# Reaction on private message in chat mode
# Param: none
# Return: none
sub messageChatCB {
    return _templateCB('chat', @_);
}

# Reaction on stand-alone private message
# Param: none
# Return: none
sub messageNormalCB {
    return _templateCB('normal', @_);
}

# Reaction on message in conference / groupchat
# Param: session id
# Param: message
# Return: none
sub messageGroupChatCB {
    my $sid = shift;
    my $message = shift;

# Get message params
    my $sender=$message->GetFrom();
    my $body=$message->GetBody();
    my $thread=$message->GetThread();

# Get message sending time
    my $time = eval { $message->GetX('jabber:x:delay')->GetStamp };
    if (defined $time) {
	$time = ($time =~ /^(\d{4,4})(\d{2,2})(\d{2,2})T(\d{2,2}):(\d{2,2}):(\d{2,2})$/) ?
		mktime($6, $5, $4, $3, ($2 - 1), ($1 - 1900)) : undef;
    }

# Jabbot listen only for messages referencing him (by name or by nick)
    my $name = $config->{'commands'}->{'groupchat'}->{' name'};
    my $nick = $config->{'commands'}->{'groupchat'}->{' nick'};

# Get sender's nick and the name of conference
    my $user = $sender;
    $user =~ s/^(.*)\///;
# It's Jabbots' own message - ignore it
    return if ($user eq $nick);
    my $room = $1;
    $sender = $room;
    return unless defined $room;
    $room =~ s/\@.*$//;

# Message should be processed only if it's sending time doesn't set
# (as of standard it means that message was sent a couple of seconds ago)
# or sending time is greater than the moment when Jabbot entered the conference
    if ((!defined $time) ||
	($time > $cache->{'static'}->{'_conf'}->{$room}->{'visit_time'})) {

# Corrected conference name - with conference hostname
        $room .= '@' . $config->{'conferences'};

        foreach ($body, $name, $nick) {
	    _utf8_on($_);
	    $_ = lc($_);
	    _utf8_off($_);
	}

# Check for whether this message is a command for Jabbot...
	if (($body =~ s/^\s*$name[\s,!]+//) || ($body =~ s/^\s*$nick[\s,!]+//)) {
# ...if so - get Jabbot reply...
	    my $result = _trueCB( 'groupchat', $sid, $user,
				  $sender, $body, $thread );
# ...and write it into history
	    _history( $user, 'in_' . $room, $body, $result );
	}

    }
    return;
}

# Template function for reaction on private messages
# Param: message mode (normal or chat)
# Param: session id
# Param: sender (JID with resource)
# Param: message body
# Param: message thread
# Return: none
sub _templateCB {
	my $mode = shift;
	my $sid = shift;
	my $message = shift;
	my $sender=$message->GetFrom();
	my $body=$message->GetBody();
	my $thread=$message->GetThread();

# Get sender JID (remove resource)
	my $user = $sender;
	$user =~ s/\/.*$//;

	_utf8_off($body);

# Get real Jabbot reaction on message
	my $result = _trueCB($mode, $sid, $user, $sender, $body, $thread);

# Write message and reply into history
	_history($user, $mode, $body, $result);

	return;
}

# Real Jabbot reaction on any command message
# Param: command mode (normal, chat, groupchat)
# Param: session id
# Param: sender (JID or nick in groupchat)
# Param: sender (JID with resource or room in groupchat mode)
# Param: message body
# Param: message thread
# Return: Jabbot reply or none
sub _trueCB {
	my $mode = shift;
	my $sid = shift;
	my $user = shift;
	my $sender = shift;
	my $body = shift;
	my $thread = shift;

	my $reply='';

# Get command message and it's possible arguments
	if ($body =~ /^(.+?)([\s,!\.]+(.*))?$/m) {
	    my $act = $1;
	    _utf8_on($act);
	    $act = lc($act);
	    _utf8_off($act);
	    my $reply = $3 || '';
# Check for unknown action
	    my $action = $config->{'commands'}->{$mode}->{$act};
	    if (defined $action) {
# Action known
# Check for forbidden action
		my $permission = 1;
		if ((defined $action->{'users'})
		    && (ref($action->{'users'}) eq 'ARRAY')) {

		    $permission = 0;
		    foreach (@{$action->{'users'}}) {
			if ($_ eq $user) {
			    $permission = 1;
			    last;
			}
		    }
		}
		if ($permission) {
# Action permitted
# Check for whether there will be any output on command
		    my $process = $action->{'process'};
		    if (defined $process) {
# Plug in action module and call processor of the given command
			my ($module, $func) = split('/', $process);
			eval "require $module";
# Check for errors on module connection
			unless ($@) {
			    *func = $module . '::' . $func;
			    eval { $reply = func( {
						    'args' => _split_args($reply),
						    'command' => $act,
						    'user' => $user,
						    'cache' => \$cache,
						    'config' => $config,
						    'mode' => $mode,
						    'client' => \$client } );
			    };
			    if ($@) {
# Something went wrong - function execution failed - try to call failover function
				my $temp = $@;
				$reply = eval { fail($temp); } ||
					 $cache->{'runtime'}->{'locale'}->locale($config->{'errors'}->{'fail'}) . $temp;
			    }
			} else {
			    my $temp = $@;
			    $reply = eval { fail($temp); } ||
				     $cache->{'runtime'}->{'locale'}->locale($config->{'errors'}->{'fail'}) . $temp;
			}
			_utf8_off($reply);
		    }
# Define finite Jabbot reaction on command (will it be result output or service action)
		    my $function = $action->{'action'};
		    if (defined $function) {
			*func = $function;
			eval { func($reply, $sender, $thread); };
			if ($@) {
# Something went wrong - function execution failed - try to call failover function
			    my $temp = $@;
			    $reply .= eval { fail($temp); } ||
				     $cache->{'runtime'}->{'locale'}->locale($config->{'errors'}->{'fail'}) . $temp;
# ...and call for corresponding finite Jabbot reaction
			    *func = $mode;
			    func($reply, $sender, $thread);
			}
		    }
# Return result: processor output (if exists) or empty string
		    return $process && $reply || '';
		} else {
# Action denied - call for corresponding processor...
		    $reply = eval { forbidden( {
					 'args' => _split_args($reply),
					 'command' => $act,
					 'user' => $user,
					 'cache' => \$cache,
					 'config' => $config,
					 'mode' => $mode,
					 'client' => \$client } ) } ||
			     $cache->{'runtime'}->{'locale'}->locale($config->{'errors'}->{'forbidden'});
# ...and call for corresponding finite Jabbot reaction
		    *func = $mode;
		    func($reply, $sender, $thread);
		    return $reply;
		}
	    } else {
# Action unknown - call for corresponding processor...
		$reply = eval {not_found( {
				     'args' => _split_args($reply),
				     'command' => $act,
				     'user' => $user,
				     'cache' => \$cache,
				     'config' => $config,
				     'mode' => $mode,
				     'client' => \$client } ) } ||
			$cache->{'runtime'}->{'locale'}->locale($config->{'errors'}->{'not_found'});
# ...and call for corresponding finite Jabbot reaction
		*func = $mode;
		func($reply, $sender, $thread);
		return $reply;
	    }
	}

	return;
}

################################ Finite reactions ###############################

# Connection termination
# Param: none
# Return: none
sub disconnect {
# Prepare static part of the cache to store it for the next run
    local $Data::Dumper::Indent = 0;
    $cache = Dumper($cache->{'static'});
    $cache =~ s{\$VAR1 = }{};

# Store static part of cache
    if (open(OUT, '>' . $config->{'cache'})) {
	if (flock(OUT, 2)) {
	    print OUT $cache;
	}
	else {
	    log_it("Jabbot core/disconnect: Can't lock cache file $config->{'cache'} for write: $!\n", 'error');
	}
	unless (close OUT) {
	    log_it("Jabbot core/disconnect: Can't close cache file $config->{'cache'}: $!\n", 'error');
	}
    }
    else {
	log_it("Jabbot core/disconnect: Can't open cache file $config->{'cache'} for write: $!", 'error');
    }

# Set 'die flag' to prevent further reconnections
    $die_flag = 1;

# Disconnect
    $client->Disconnect();

    return;
}

# Joining the conference / groupchat
# Param: conference (room) name
# Return: none
sub enter_room {
    my $room = shift;
    $client->PresenceSend( to => $room . '@' . $config->{'conferences'} . '/' .
				$config->{'commands'}->{'groupchat'}->{' nick'},
			   show => "online" ) if ($room ne '');
    $cache->{'static'}->{'_conf'}->{$room}->{'visit_time'} = time;
    return;
}

# Leaving the conference / groupchat
# Param: conference (room) name
# Return: none
sub exit_room {
# Note: in case when command to leave the conference was sent in chat or normal
# mode, the room name is the first parameter. And in case when that command was
# sent in groupchat mode then the first parameter is empty and the room name can
# be defined based upon the sender's JID.
    my $room = shift;
    unless ($room) {
	$room = shift;
	$room =~ s/@.*$//;
    }
    $client->PresenceSend( to => $room . '@' . $config->{'conferences'} . '/' .
				$config->{'commands'}->{'groupchat'}->{' nick'},
			   type => "unavailable" ) if ($room ne '');
    return;
}

# Private message in chat mode
# Param: message
# Param: recipient
# Param: thread
# Param: subject
# Return: none
sub chat {
    _message('chat', @_);
    return;
}

# Groupchat message
# Param: message
# Param: recipient
# Param: thread
# Param: subject
# Return: none
sub groupchat {
    _message('groupchat', @_);
    return;
}

# Private message in normal mode
# Param: message
# Param: recipient
# Param: thread
# Param: subject
# Return: none
sub normal {
    _message('normal', @_);
    return;
}

# Empty reaction
# Param: none
# Return: none
sub empty {
    return;
}

########################### Internal service functions ##########################

# Function to send some message
# Param: message mode (chat, normal, groupchat)
# Param: message
# Param: recipient
# Param: thread
# Param: subject
# Return: none
sub _message {
    my $type = shift;
    my $message = shift;
    my $rcpt = shift;
    my $thread = shift;
    my $subject = shift;

    _utf8_on($message);

    $client->MessageSend(
			to	=> $rcpt,
			subject	=> $subject || '',
			body	=> $message,
			type	=> $type,
			thread	=> $thread
    );
    return;
}

# Write item into history of messages
# Param: user
# Param: message mode
# Param: user's request
# Param: Jabbot's reply
# Return: 1 on success, 0 on error
sub _history {
	my $user = shift;
	my $mode = shift;
	my $request = shift;
	my $reply = shift;

# Skip history if Jabbot is told not to store it
	return 1 unless $config->{'store_history'};

# Compose history item
	my $string = "\n>" . $request . "\n<" . join("\n<", split("\n", $reply)) . "\n@@@";

# Check for history directory and try to create it if needed
	unless (-d $config->{'history'}) {
	    unless (mkdir($config->{'history'}, 0750)) {
		log_it("Jabbot core/_history: Can't create history directory: $!", 'error');
	    }
	}

# Write item into history
	return write_to_file($string, $config->{'history'} . '/' . $user . '_' . $mode . '.history');

}

# Parse arguments from string into array
# Param: string with arguments
# Return: reference to arguments array
sub _split_args {
	my $string = shift;
	my @args;

# Note: arguments is space separated.
# To include space into argument double quotes can be used.
# To use double quotes as is - escape it with backslash.

	if (defined $string) {
	    $string =~ s/\\\"/\0/g;
	    while ($string =~ /\"([^\"]*)\"|(\S+)/g) {
		my $temp = $+;
		$temp =~ s/\0/\"/g;
	        $temp =~ s/^\s+//;
		$temp =~ s/\s+$//;
	        push (@args, $temp) unless ($temp =~ /^[\s\"]?$/);
	    }
	}

	return \@args;
}
