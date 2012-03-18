package SpamSvc::FrequencyTracker;

use strict;
use warnings;

use Cache::Memory;
use Time::HiRes 'time';

sub new {
    my $that 	= shift;
    my $class 	= ref $that || $that;
    my %params  = @_;

    my $self = {
        halflife    => 60,
        namespace   => rand(),
        %params
    };

    unless ($self->{cache}) {
        $self->{cache} = Cache::Memory->new(
            namespace           => $self->{namespace},
            size_limit          => $self->{size} || 1_000_000,
            removal_strategy    => 'Cache::RemovalStrategy::LRU',
        );
    }

    bless $self, $class;
}

=for comment

The equilibrium "score" for an object seen every t seconds is:

        inf
        ---      -(n*t)/t_half
         \  / 1 \                    1
    s =  /  | - |            = -------------
        --- \ 2 /                     t/t_half
        n=1                     -1 + 2


where t_half is the decay half-life.

Sample equilibrium scores:

Frequency   Halflife    Equilibrium score
---------   --------    -----------------
1s          60s         87.063
5s          60s         17.817
10s         60s         9.166
15s         60s         6.285
30s         60s         3.414
60s         60s         2.000
120s        60s         1.333
300s        60s         1.032
1s          300s        433.309
5s          300s        87.063
10s         300s        43.783
15s         300s        29.357
30s         300s        14.933
60s         300s        7.725
120s        300s        4.130
300s        300s        2.000
1s          3600s       5194.202
5s          3600s       1039.241
10s         3600s       519.870
15s         3600s       346.747
30s         3600s       173.624
60s         3600s       87.063
120s        3600s       43.783
300s        3600s       17.817
900s        3600s       6.285
3600s       3600s       2.000

=cut


sub score {
    my SpamSvc::FrequencyTracker $self = shift;
    my $key = shift;
    my $now_time = shift || time;

    my $score = 0;

    my $cached_time = $self->{cache}->get("$self->{namespace}:$key");
    if (defined $cached_time) {
        my ($saved_score, $saved_time) = unpack 'dI', $cached_time;
        my $elapsed = $now_time - $saved_time;

        # discount the score for time
        $score = $saved_score * 0.5**($elapsed/$self->{halflife});
    }

    return ($score, $now_time);
}

sub hit {
    my SpamSvc::FrequencyTracker $self = shift;
    my $key = shift;
    my $hit_time = shift || time;
    my $now_time = shift;

    my ($score, $score_time);

    if (defined $now_time) {
        ($score, $score_time) = $self->score($key, $now_time);
        my $more = 0.5**(($score_time - $now_time) / $self->{halflife});
        $score += $more;
    }
    else {
        ($score, $score_time) = $self->score($key);
        $score++;
    }

    $self->{cache}->set("$self->{namespace}:$key", pack 'dI', $score, $score_time);

    return ($score, $score_time);
}

1;
