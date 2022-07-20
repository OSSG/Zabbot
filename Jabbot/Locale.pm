# Jabbot - localization class
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

package Jabbot::Locale;

use strict;
use warnings;

use Jabbot::Service qw(log_it);

# Class constructor
# Param: package name
# Param: locale filename
# Return: locale object
sub new {
    my $package = shift;
    my $locale_file = shift;

    my $self = {};

# Try to init hash with localized constants
    if (defined $locale_file && -f $locale_file) {
	$self->{'locale'} = do($locale_file);
	if ($@) {
	    log_it("Jabbot::Locale/new: error on locale file init: $@. Will use default.", 'warn');
	    delete $self->{'locale'};
	}
    }
    else {
	log_it('Jabbot::Locale/new: locale file not defined or not found. Will use default.', 'warn');
    }

    $self = bless($self, $package);

    return $self;
}

# Get string translation
# Param: string to translate
# Return: translated string or given string if translation was not found
sub locale {
	my $self = shift;
	my $string = shift;

	return defined $self->{'locale'}->{$string} ?
		$self->{'locale'}->{$string} :
		$string;
}


1;
