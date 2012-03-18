package SpamSvc::DisplayAligned;

use strict;
use warnings;

use IO::String;
use CGI ':standard';

use base 'IO::String';

our $num_separator_columns = 2;

sub new {
    my $class = shift;
    my $ref = ref $class || $class;
    my $self = IO::String->new();
    my %args = (
        fancy => 0,
        as_html => 0,
        @_
    );
    bless $self, $class;
    $self->_displayed(0);
    $self->fancy($args{fancy});
    $self->as_html($args{as_html});
    return $self;
}

sub DESTROY {
    my $self = shift;
    $self->display_aligned()
        unless $self->_displayed;
}

sub _prop {
    my $self = shift;
    my $prop = shift;
    my $arg = shift;
    no strict 'refs';
    my $storage = ${''.__PACKAGE__}{$self} ||= {};
    return undef unless $storage;
    if (defined $arg) {
        return $storage->{$prop} = $arg;
    }
    else {
        return $storage->{$prop};
    }
}

sub _displayed {
    return $_[0]->_prop('_displayed', $_[1]);
}

sub fancy {
    return $_[0]->_prop('fancy', $_[1]);
}

sub as_html {
    return $_[0]->_prop('as_html', $_[1]);
}

sub display_aligned {
    my $self = shift;
    my @lines = split /[\r\n]+/, ${ $self->string_ref };
    my @rows;
    for my $line (@lines) {
        push @rows, [split /\t/, $line];
    }
    my $headers = shift @rows;
    $self->display_table(\@rows, $headers);
}

sub display_table {
    my $self = shift;
    if ($self->as_html) {
        print $self->generate_html(@_);
    }
    else {
        print $self->align(@_);
    }
    $self->_displayed(1);
}

sub align {
    my $self = shift;
    my $rows = shift;
    my $headers = shift;

    my $output = '';

    return unless $rows && @$rows;

    my @field_max_length;
    my $num_fields = 0;
    for my $row (@$rows, $headers) {
        next unless defined $row;
        for my $i (0..@$row-1) {
            my $length = length $row->[$i];
            $field_max_length[$i] = $length if !defined $field_max_length[$i] || $length > $field_max_length[$i];
            $num_fields = $i+1 if $i >= $num_fields;
        }
    }

    my ($vert_sep, $col_sep, $left_bump, $right_bump);

    if ($self->fancy) {
        $vert_sep .= '+-';
        for my $i (0..$num_fields-1) {
            $vert_sep .= '-+-' if $i;
            $vert_sep .= sprintf '-'x$field_max_length[$i];
        }
        $vert_sep .= "-+\n";

        $col_sep    = ' | ';
        $left_bump  = '| ';
        $right_bump = ' |';
    }
    else {
        $vert_sep   = '';
        $col_sep    = ' ' x $num_separator_columns;
        $left_bump  = '';
        $right_bump = '';
    }

    # headers
    if ($headers) {
        $output .= $vert_sep;
        $output .= $left_bump;
        for my $i (0..$num_fields-1) {
            $output .= $col_sep if $i;
            my $col_width = $field_max_length[$i];
            my $header_width = length $headers->[$i];
            my $left_spacing = int(($col_width-$header_width)/2);
            my $remaining = $col_width - $left_spacing;
            my $header = $headers->[$i];
            $header = '' unless defined $header;
            $output .= sprintf "%${left_spacing}s%-${remaining}s", '', $header;
        }
        $output .= $right_bump;
        $output .= "\n";
    }

    # separators
    $output .= $vert_sep;

    # data
    for my $line_ref (@$rows) {
        $output .= $left_bump;
        for my $i (0..$num_fields-1) {
            $output .= $col_sep if $i;
            my $l = $field_max_length[$i];
            my $field = $line_ref->[$i];
            $field = '' unless defined $field;
            $output .= sprintf "%${l}s", $field;
        }
        $output .= $right_bump;
        $output .= "\n";
    }

    $output .= $vert_sep;

    return $output;
}

sub generate_html {
    my $self = shift;
    my $rows = shift;
    my $headers = shift;
    my $class = shift;

    return unless $rows && @$rows;

    my @trs;
    if ($headers) {
        my @ths;
        my $i = 1;
        for my $col (@$headers) {
            push @ths, th({-class => "col$i"}, $col);
            $i++;
        }
        push @trs, \@ths;
    }

    for my $row (@$rows) {
        my @tds;
        my $i = 1;
        for my $col (@$row) {
            push @tds, td({-class => "col$i"}, $col);
            $i++;
        }
        push @trs, \@tds;
    }

    return table(map {Tr(@$_)} @trs);
}

1;
