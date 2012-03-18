#!/usr/bin/perl

# generates sql that converts serotype_log tables from innodb to archive engine.

use strict;
use warnings;

use Getopt::Long;
use POSIX 'strftime';
use SpamSvc::Serotype::Util 'str2time';

GetOptions(
    'start=s'   => \(my $start),
    'end=s'     => \(my $end),
    'only=s'    => \(my $only),
);

$start = shift if !$start && @ARGV;
$end = shift if !$end && @ARGV;
$end = $start unless $end;

die "usage: $0 <start> <end>\n" unless $start && $end;

# things that must be removed for engine=archive: indexes, primary keys, autoinc columns

my %tables = (
    request_log => {
        indexes     => [qw/ id date_id action_dim_id api_key_dim_id ip_dim_id user_ip_dim_id type_dim_id rating /],
        primary_key => 1,
    },
    ext_meta    => {
        primary_key => 1,
    },
    param_dim   => {
        primary_key => 1,
        modify      => ['param_dim_id INT UNSIGNED NOT NULL'],
    },
    factors_dim => {
        primary_key => 1,
        modify      => ['factors_dim_id INT UNSIGNED NOT NULL'],
    },
);

my $start_time = str2time $start;
my $end_time = str2time $end;

for (my $time = $start_time; $time <= $end_time; $time += 24*60*60) {
    my $date = strftime '%F', localtime $time;
    $date =~ tr/-/_/;
    for my $table (keys %tables) {
        my $t = $tables{$table};
        next if $only && $table ne $only;
        my @alterations;
        if (my $indexes = $t->{indexes}) {
            push @alterations, map { "DROP INDEX $_" } @$indexes;
        }
        if ($t->{primary_key}){
            push @alterations, 'DROP PRIMARY KEY';
        }
        if (my $column = $t->{auto_inc}){
            push @alterations, 'DROP PRIMARY KEY';
        }
        if (my $modifications = $t->{modify}){
            for (@$modifications) {
                push @alterations, "MODIFY $_";
            }
        }

        my $td = 'serotype_log.' . $table . '_' . $date;
        printf "ALTER TABLE $td %s;\n", join ', ', @alterations if @alterations;
        print "ALTER TABLE $td ENGINE=Archive;\n";
    }
}

warn "Don't forget to FLUSH TABLES before copy/dropping\n";
