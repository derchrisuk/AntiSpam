package SpamSvc::Serotype::Log::Meta;

use strict;
use warnings;

use Carp;

use fields qw(
    props
    prop_lookup
    enum_lookup
);

use constant {
    INT2STR => 0,
    STR2INT => 1,
};

sub new {
    my $class = shift;
    my $config = shift;

    my $self = $class;
    $self = fields::new($class) unless ref $self;

    my $p = $self->{props} = $config->{log_meta_props};
    for my $prop (keys %$p) {
        my $prop_index = $p->{$prop}{index};
        $self->{prop_lookup}[STR2INT]{$prop} = $prop_index;
        $self->{prop_lookup}[INT2STR]{$prop_index} = $prop;

        my $type = $self->prop_type($prop);
        if ($type eq 'enum') {
            my $e = $p->{$prop}{enum};
            $self->{enum_lookup}[INT2STR]{$prop} = {%$e};
            $self->{enum_lookup}[STR2INT]{$prop} = {reverse %$e};
        }
    }

    return $self;
}

sub prop_type {
    my $self = shift;
    my $prop = shift;
    return $self->{props}{$prop}{type};
}

sub prop_str2int {
    my $self = shift;
    my $prop = shift;
    return $self->{prop_lookup}[STR2INT]{$prop};
}

sub prop_int2str {
    my $self = shift;
    my $index = shift;
    return $self->{prop_lookup}[INT2STR]{$index};
}

sub enum_str2int {
    my $self = shift;
    my $prop = shift;
    my $str = shift;
    return $self->{enum_lookup}[STR2INT]{$prop}{$str};
}

sub enum_int2str {
    my $self = shift;
    my $prop = shift;
    my $index = shift;
    return $self->{enum_lookup}[INT2STR]{$prop}{$index};
}

sub strings {
    my $self = shift;
    my $prop = shift;
    return keys %{ $self->{enum_lookup}[STR2INT]{$prop} };
}

sub indexes {
    my $self = shift;
    my $prop = shift;
    return keys %{ $self->{enum_lookup}[INT2STR]{$prop} };
}

sub normalize_bool {
    my $self = shift;
    my $value = lc shift;

    return 0 if !$value || $value eq 'false' || $value eq 'no';
    return 1;
}

sub user_value_to_db_pair {
    my $self = shift;
    my $prop = shift;
    my $value = shift;

    my $type = $self->prop_type($prop);

    if ($type eq 'enum') {
        return $self->enum_str2int($prop, $value), 'int';
    }
    elsif ($type eq 'boolean') {
        return $self->normalize_bool($value), $type;
    }
    # TODO validators for other set_meta_* types
    else {
        return $value, $type;
    }
}

# must match order of CREATE TABLE ext_meta_*
use constant {
    META_REQUEST_LOG_ID     => 0,
    META_TYPE_ID            => 1,
    META_BOOLEAN            => 2,
    META_INT                => 3,
    META_FLOAT              => 4,
    META_DATE               => 5,
    META_STRING             => 6,
    META_BLOB               => 7,
};

sub db_row_to_prop_and_value {
    my $self = shift;
    my $row  = shift;

    my $prop = $self->prop_int2str($row->[META_TYPE_ID]);
    my $type = $self->prop_type($prop);

    if ($type eq 'boolean') {
        return $prop, $row->[META_BOOLEAN];
    }
    elsif ($type eq 'int') {
        return $prop, $row->[META_INT];
    }
    elsif ($type eq 'float') {
        return $prop, $row->[META_FLOAT];
    }
    elsif ($type eq 'date') {
        return $prop, $row->[META_DATE];
    }
    elsif ($type eq 'string') {
        return $prop, $row->[META_STRING];
    }
    elsif ($type eq 'blob') {
        return $prop, $row->[META_BLOB];
    }
    elsif ($type eq 'enum') {
        return $prop, $self->enum_int2str($prop, $row->[META_INT]);
    }
    return undef;
}

1;
