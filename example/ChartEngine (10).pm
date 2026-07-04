package Market::Overlays::SMC_Structures;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = {
        smc_result  => $args{smc_result},
        show_zigzag => $args{show_zigzag} // 1,
        show_labels => $args{show_labels} // 1,
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $smc_result) = @_;
    $self->{smc_result} = $smc_result;
}

sub draw {
    my ($self, $canvas, $start, $end, $x_of, $state, $price_panel) = @_;

    return if !$self->{show_zigzag};
    return if !$self->{smc_result};
    return if !$self->{smc_result}->{structure};

    my $structure = $self->{smc_result}->{structure};
    my $scale     = $price_panel->{scale};

    return if !defined $state->{right};
    return if $state->{right} <= 0;

    my $right_limit = $state->{right} - 5;

    my @pivots_to_draw;
    my $prev_pivot;
    my $next_pivot;

    for my $p (@$structure) {
        if ($p->{index} < $start) {
            $prev_pivot = $p;
            next;
        }

        if ($p->{index} > $end) {
            $next_pivot = $p;
            last;
        }

        push @pivots_to_draw, $p;
    }

    unshift @pivots_to_draw, $prev_pivot if defined $prev_pivot;
    push @pivots_to_draw, $next_pivot if defined $next_pivot;

    my @visible_points;

    for my $p (@pivots_to_draw) {
        my $local_i = $p->{index} - $start;
        my $x = $x_of->($local_i);

        next if !defined $x;

        my $y = $scale->price_to_y(
            $p->{price},
            $state->{price_min},
            $state->{price_max},
            0,
            $state->{price_h}
        );

        next if !defined $y;

        push @visible_points, {
            x     => $x,
            y     => $y,
            label => $p->{label},
            type  => $p->{type},
            price => $p->{price},
            index => $p->{index},
        };
    }

    return if @visible_points < 2;

    for my $i (1 .. $#visible_points) {
        my $a = $visible_points[$i - 1];
        my $b = $visible_points[$i];

        my ($x1, $y1) = ($a->{x}, $a->{y});
        my ($x2, $y2) = ($b->{x}, $b->{y});

        next if $x1 > $right_limit && $x2 > $right_limit;

        if ($x2 > $right_limit && $x2 != $x1) {
            my $t = ($right_limit - $x1) / ($x2 - $x1);
            $x2 = $right_limit;
            $y2 = $y1 + $t * ($y2 - $y1);
        }

        if ($x1 > $right_limit && $x1 != $x2) {
            my $t = ($right_limit - $x2) / ($x1 - $x2);
            $x1 = $right_limit;
            $y1 = $y2 + $t * ($y1 - $y2);
        }

        $canvas->createLine(
            $x1, $y1,
            $x2, $y2,
            -fill  => '#2962ff',
            -width => 2
        );
    }

    for my $p (@visible_points) {
        next if $p->{x} > $right_limit;

        my $r = 3;

        $canvas->createOval(
            $p->{x} - $r, $p->{y} - $r,
            $p->{x} + $r, $p->{y} + $r,
            -fill    => '#2962ff',
            -outline => '#2962ff'
        );

        next if !$self->{show_labels};
        next if !defined $p->{label};
        next if $p->{label} eq 'H';
        next if $p->{label} eq 'L';

        my $dy = $p->{type} eq 'HIGH' ? -14 : 14;

        $canvas->createText(
            $p->{x},
            $p->{y} + $dy,
            -text   => $p->{label},
            -fill   => '#111111',
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;