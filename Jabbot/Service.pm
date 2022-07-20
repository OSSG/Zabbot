# Jabbot - misc service functions
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

package Jabbot::Service;

use strict;
use warnings;

use Encode qw(_utf8_on _utf8_off);

use Exporter;

@Jabbot::Service::ISA = ('Exporter');
@Jabbot::Service::EXPORT = qw(&format_string &write_to_file &log_it);

# Add date and time to string
# Param: string
# Param: type (optional)
# Return: formatted string
sub format_string {
    my $string = shift;
    my $type = shift;
    _utf8_off($string);
    $string = "[$type] $string" if defined $type;
    return '[' . localtime(time) . "] $string\n";
}

# Output formatted string
# Param: string
# Param (optional): event type (default - 'info')
# Return: 1
sub log_it {
	my $string = shift;
	my $type = shift || 'info';
	print format_string($string, $type);
	return 1;
}

# Write string to a given file
# Param: string
# Param: filename
# Return: 1 on success, 0 on error
sub write_to_file {
	my $string = shift;
	my $file = shift;

	if (open(FILE, '>>' . $file)) {
	    if (flock(FILE, 2)) {
		print FILE format_string($string);
	    }
	    else {
		log_it("Jabbot::Service/write_to_file: Can't lock file $file: $!", 'error');
		return 0;
	    }

	    unless (close FILE) {
		log_it("Jabbot::Service/write_to_file: Can't close file $file: $!", 'error');
		return 0;
	    }

	}
	else {
	    log_it("Jabbot::Service/write_to_file: Can't open file $file to write: $!", 'error');
	    return 0;
	}

    return 1;
}

1;
