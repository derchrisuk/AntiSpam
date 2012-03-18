# $Id: Generator.pm 1029 2005-11-22 07:11:22Z btrott $

package Data::YUID::Generator;
use strict;
use warnings;
no warnings qw(deprecated); # for fields

use vars qw{$VERSION};
$VERSION = "0.01";

use fields qw(host_id start_time current_time min_id max_id ids);

use constant EPOCH_OFFSET => 946684800; # Sat, Jan 1 2000 00:00 GMT

use constant HOST_ID_BITS => 16;
use constant TIME_BITS => 36;
use constant SERIAL_BITS => 64 - HOST_ID_BITS - TIME_BITS;

use constant TIME_SHIFT => HOST_ID_BITS + SERIAL_BITS;
use constant SERIAL_SHIFT => HOST_ID_BITS;

use constant SERIAL_INCREMENT => 1 << SERIAL_SHIFT;

use constant HOST_ID_MAX => (1 << HOST_ID_BITS) - 1;
use constant TIME_MAX => (1 << TIME_BITS) - 1;
use constant TIME_MAX_SHIFTED => TIME_MAX << TIME_SHIFT;
use constant SERIAL_MAX => (1 << SERIAL_BITS) - 1;
use constant SERIAL_MAX_SHIFTED => SERIAL_MAX << SERIAL_SHIFT;


sub new {
    my Data::YUID::Generator $self = shift;
    $self = fields::new( $self ) unless ref $self;
    
    my $host_id = shift;
    if( !$host_id ) {
        $host_id = int( rand( HOST_ID_MAX ) );
    } elsif( $host_id < 0 || $host_id > HOST_ID_MAX ) {
        warn __PACKAGE__ . ": host ID $host_id is not in range of [0," . HOST_ID_MAX . "]\n";
        return undef;
    }
    
    $self->{ host_id } = $host_id;
    $self->{ start_time } = time;
    $self->{ current_time } = 0;
    $self->{ ids } = {};
    $self->_sync();
    
    return $self;
}


sub _sync {
    my $self = shift;
    my $time = time;
    return if( $self->{ current_time } == $time ); # FIXME: check for clock skew
    $self->{ current_time } = $time;
    $self->{ min_id } = $self->_make_id( 0 ) unless( $self->{ min_id } );
    $self->{ max_id } = $self->_make_id( SERIAL_MAX );
}


sub _make_id ($) {
    my $self = shift;
    my $serial = shift || 0;
    return (($self->{ current_time } - EPOCH_OFFSET) << TIME_SHIFT) |
        ($serial << SERIAL_SHIFT) | $self->{ host_id };
        
}


sub get_id ($) {
    my $self = shift;
    my $key = shift || "_";
    $self->_sync();
    
    if( !exists $self->{ ids }->{ $key } ) {
        $self->{ ids }->{ $key } = $self->{ min_id };
        return $self->{ ids }->{ $key };
    }
    
    return undef
        if( $self->{ ids }->{ $key } >= $self->{ max_id } );
    
    $self->{ ids }->{ $key } += SERIAL_INCREMENT;
    return $self->{ ids }->{ $key };
}


1;
