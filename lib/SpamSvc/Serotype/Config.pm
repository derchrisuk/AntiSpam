package SpamSvc::Serotype::Config;

use strict;
use warnings;

use File::Spec;
use YAML::Syck qw/Load Dump LoadFile DumpFile/;

use base 'Exporter';

our @EXPORT_OK = qw/load_config/;

sub load_config # {{{
{
    my $config_file = shift;

    my $config = LoadFile($config_file);

    my $include = delete $config->{include};

    my @files = ($config_file);

    if (defined $include) {

        my @includes;
        if (ref $include eq 'ARRAY') {
            @includes = @$include;
        }
        elsif (!ref $include) {
            @includes = ($include);
        }

        for my $file (@includes) {
            if (!-e $file) {
                my (undef, $dir) = File::Spec->splitpath($config_file);
                $dir =~ s,/$,,;
                my $path = "$dir/$file";
                $file = $path if -e $path;
            }

            if (!-r $file) {
                warn "warning: can't read included config file $file\n";
                next;
            }

            my ($sub_config, $sub_files) = load_config($file);
            push @files, $_ for @$sub_files;
            $config->{$_} = $sub_config->{$_} for keys %$sub_config;
        }
    }

    if (wantarray) {
        return ($config, \@files);
    }
    else {
        return $config;
    }
}

1;

# vim: foldmethod=marker
