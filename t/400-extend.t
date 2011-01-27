#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 1;

use lib 't/lib';
use MyPDD;

my @calls;

do {
    package MyDispatcher;
    use MyPDD -base;

    command 'foo' => sub { push @calls, "win" };
};

MyDispatcher->run('command_foo');
is_deeply([splice @calls], ['win']);
