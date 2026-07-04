package Market::Overlays::Liquidity;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = {
        liq_result => $args{liq_result},
        show_bsl   => $args{show_bsl} // 1,
        show_ssl   => $args{show_ssl} // 1,
        show_eqh   => $args{show_eqh} // 1,
        show_eql   => $args{show_eql} // 1,
    };

    return bless $self, $class;
}

sub set_result {
    my ($self, $liq_result) = @_;
    $self->{liq_result} = $liq_result;
}

sub draw {
    my ($self, $canvas, $start, $end, $x_of, $state, $price_panel) = @_;

    return if !$self->{liq_result};

    my $scale = $price_panel->{scale};

    return if !defined $state->{right};
    return if $state->{right} <= 0;

    my $right_limit = $state->{right} - 5;

    $self->_draw_bsl_ssl($canvas, $start, $end, $x_of, $state, $scale, $right_limit);
    $self->_draw_eqh_eql($canvas, $start, $end, $x_of, $state, $scale, $right_limit);
}

sub _draw_bsl_ssl {
    my ($self, $canvas, $start, $end, $x_of, $state, $scale, $right_limit) = @_;

    my $levels = $self->{liq_result}->{liquidity} || [];

    for my $lvl (@$levels) {
        my $created_index  = $lvl->{created_index} // $lvl->{index};
        my $resolved_index = $lvl->{resolved_index} // $end;

        next if $resolved_index < $start;
        next if $created_index > $end;

        next if $lvl->{type} eq 'BSL' && !$self->{show_bsl};
        next if $lvl->{type} eq 'SSL' && !$self->{show_ssl};

        my $local_i = $lvl->{index} - $start;
        my $x1 = $x_of->($local_i);
        my $end_index = defined $lvl->{resolved_index}
            ? $lvl->{resolved_index}
            : $end;

        my $x2 = $x_of->($end_index - $start);
        $x2 = $right_limit if $x2 > $right_limit;

        my $y = $scale->price_to_y(
            $lvl->{price},
            $state->{price_min},
            $state->{price_max},
            0,
            $state->{price_h}
        );

        my $color = $lvl->{type} eq 'BSL' ? '#f23645' : '#089981';

        $canvas->createLine(
            $x1, $y,
            $x2, $y,
            -fill  => $color,
            -dash  => [4, 4],
            -width => 1
        );

        $canvas->createText(
            $x2 - 4,
            $y - 8,
            -text   => $lvl->{type},
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'e'
        );
    }
}

sub _draw_eqh_eql {
    my ($self, $canvas, $start, $end, $x_of, $state, $scale, $right_limit) = @_;

    my $equals = $self->{liq_result}->{equal_levels} || [];

    for my $eq (@$equals) {
        next if $eq->{index2} < $start;
        next if $eq->{index1} > $end;

        next if $eq->{type} eq 'EQH' && !$self->{show_eqh};
        next if $eq->{type} eq 'EQL' && !$self->{show_eql};

        my $x1 = $x_of->($eq->{index1} - $start);
        my $x2 = $x_of->($eq->{index2} - $start);

        $x1 = $state->{left} if $x1 < $state->{left};
        $x2 = $right_limit if $x2 > $right_limit;

        my $y = $scale->price_to_y(
            $eq->{price},
            $state->{price_min},
            $state->{price_max},
            0,
            $state->{price_h}
        );

        my $color = $eq->{type} eq 'EQH' ? '#d32f2f' : '#00796b';

        $canvas->createLine(
            $x1, $y,
            $x2, $y,
            -fill  => $color,
            -dash  => [2, 3],
            -width => 1
        );

        my $label_x = ($x1 + $x2) / 2;

        $canvas->createText(
            $label_x,
            $y + ($eq->{type} eq 'EQH' ? -10 : 10),
            -text   => $eq->{type},
            -fill   => $color,
            -font   => ['Arial', 8, 'bold'],
            -anchor => 'center'
        );
    }
}

1;