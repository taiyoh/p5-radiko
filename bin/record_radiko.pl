#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use FindBin::libs;
use Radiko;
use Getopt::Long;

my %opt;
GetOptions(
    \%opt,
    qw/channel=s minutes=f output=s/
);

for my $key (qw/channel minutes output/) {
    die "require parameter: $key" unless $opt{$key};
}

my $radiko = Radiko->new(
    channel => $opt{channel},
);

$radiko->record({
    minutes => $opt{minutes},
    output  => $opt{output}
});
