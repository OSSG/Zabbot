# Jabbot - Help action
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

package Jabbot::Actions::Help;

use strict;
use warnings;

use Jabbot::Locale;

# Compose help message
# Param: data hash
# Return: help message as string
sub help {
    my $data = shift;

    my $cache = $data->{'cache'};

    my $result = '';
    $result .= $$cache->{'runtime'}->{'locale'}->locale('This command runs without arguments')
		. "\n" if (scalar(@{$data->{'args'}}));

    my $user = $data->{'user'};
    my $config = $data->{'config'};
    my $mode = $data->{'mode'};

    $result .= $$cache->{'runtime'}->{'locale'}->locale('Can execute:') . "\n";
# Get all commands available for the given user in given mode
    foreach my $action (sort(keys %{$config->{'commands'}->{$mode}})) {

	next if ($action =~ /^\s/);

	my $permission = 1;
	if ((defined $config->{'commands'}->{$mode}->{$action}->{'users'}) &&
	    (ref($config->{'commands'}->{$mode}->{$action}->{'users'}) eq 'ARRAY')) {

	    $permission = 0;
	    foreach (@{$config->{'commands'}->{$mode}->{$action}->{'users'}}) {
		if ($_ eq $user) {
		    $permission = 1;
		    last;
		}
	    }

	}


	if ($permission) {
	    my $help = $$cache->{'runtime'}->{'locale'}->locale($config->{'commands'}->{$mode}->{$action}->{'help'} || '');
	    $result .= "\t$action" . ($help ?
			sprintf($$cache->{'runtime'}->{'locale'}->locale("\tUsage: %s"), $help) : '') . "\n";
	}

    }

    return $result;
}

1;