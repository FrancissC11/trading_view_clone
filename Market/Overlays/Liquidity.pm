package Market::Overlays::Liquidity;

# =============================================================================
# Market::Overlays::Liquidity   (Tabla 1 del PDF)
#
# Capa visual del modulo de liquidez. Lee lo ya calculado por
# Indicators/Liquidity.pm (swings, niveles BSL/SSL, EQH/EQL y eventos
# Sweep/Grab/Run) y lo dibuja segun la Tabla 2 del PDF. NO calcula nada.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Sub-toggles independientes: show_swing / show_bsl / show_ssl / show_eqh /
#   show_eql / show_sweeps / show_grabs / show_runs
#
# Las etiquetas son "tags" compactos centrados (texto blanco sobre color) con
# anti-solapamiento, para que la grafica no se sature.
# =============================================================================

use strict;
use warnings;

use constant TAG => 'overlay_liquidity';

use constant {
    C_BSL   => '#ef5350',   # rojo
    C_SSL   => '#26a69a',   # verde
    C_EQ    => '#8e24aa',   # morado (configurable)
    C_GRAB  => '#ff9800',   # naranja
    C_RUN   => '#2962ff',   # azul
    MAX_LINES => 6,         # niveles BSL/SSL resting dibujados (los mas recientes)
    MAX_EVENTS => 60,       # eventos recientes considerados por render
};

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source      => $args{source},
        show_swing  => $args{show_swing}  // 1,
        show_bsl    => $args{show_bsl}    // 1,
        show_ssl    => $args{show_ssl}    // 1,
        show_eqh    => $args{show_eqh}    // 1,
        show_eql    => $args{show_eql}    // 1,
        show_sweeps => $args{show_sweeps} // 1,
        show_grabs  => $args{show_grabs}  // 1,
        show_runs   => $args{show_runs}   // 1,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;   # cajas de etiquetas (anti-solape, compartido en el frame)
    $self->_render_swings( $canvas, $scale, $src )            if $self->{show_swing};
    $self->_render_levels( $canvas, $scale, $src, \@placed );
    $self->_render_equals( $canvas, $scale, $src, \@placed )
        if $self->{show_eqh} || $self->{show_eql};
    $self->_render_events( $canvas, $scale, $src, \@placed );
}

# -----------------------------------------------------------------------------
# Niveles BSL/SSL "resting" (aun no barridos): linea horizontal discontinua;
# la etiqueta se ancla cerca de la regleta de precio (columna ordenada) con
# anti-solape vertical.
# -----------------------------------------------------------------------------
sub _render_levels {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $levels = $src->get_levels or return;

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;
    my $x_lim  = $off + $vb;

    for my $kind ( 'buy', 'sell' ) {
        next if $kind eq 'buy'  && !$self->{show_bsl};
        next if $kind eq 'sell' && !$self->{show_ssl};

        my @resting = grep {
            $_->{side} eq $kind && $_->{state} ne 'RESOLVED'
        } @$levels;
        @resting = @resting[ -MAX_LINES .. -1 ] if @resting > MAX_LINES;

        my $color = ( $kind eq 'buy' ) ? C_BSL : C_SSL;
        my $text  = ( $kind eq 'buy' ) ? 'BSL' : 'SSL';

        for my $lv (@resting) {
            next if $lv->{index} > $x_lim;
            next unless $scale->value_in_range( $lv->{price} );

            my $y  = $scale->value_to_y( $lv->{price} );
            my $x1 = $scale->index_to_center_x( $lv->{index} );
            $x1 = 0 if $x1 < 0;

            $canvas->createLine(
                $x1, $y, $plot_w, $y,
                -fill => $color, -dash => [ 5, 4 ], -width => 1, -tags => [TAG] );

            _tag( $canvas, $plot_w - 16, $y, $text, $color, $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# Swing Points: marcador triangular pequeño (sin texto, no satura).
# -----------------------------------------------------------------------------
sub _render_swings {
    my ( $self, $canvas, $scale, $src ) = @_;
    my $swings = $src->get_swings or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    for my $sw (@$swings) {
        next if $sw->{index} < $off || $sw->{index} > $off + $vb;
        next unless $scale->value_in_range( $sw->{price} );

        my $x = $scale->index_to_center_x( $sw->{index} );
        my $y = $scale->value_to_y( $sw->{price} );
        my $up = ( $sw->{kind} eq 'H' );
        my $color = $up ? C_BSL : C_SSL;
        my $dy = $up ? -6 : 6;

        $canvas->createLine( $x - 4, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
        $canvas->createLine( $x + 4, $y + $dy, $x, $y,
            -fill => $color, -width => 1, -tags => [TAG] );
    }
}

# -----------------------------------------------------------------------------
# EQH / EQL: linea que conecta ambos pivotes iguales + etiqueta compacta.
# -----------------------------------------------------------------------------
sub _render_equals {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $eqs = $src->get_equals or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    for my $e (@$eqs) {
        my $is_high = ( $e->{kind} eq 'EQH' );
        next if $is_high  && !$self->{show_eqh};
        next if !$is_high && !$self->{show_eql};

        next if $e->{i2} < $off || $e->{i1} > $off + $vb;
        next unless $scale->value_in_range( $e->{p1} )
                 || $scale->value_in_range( $e->{p2} );

        my $x1 = $scale->index_to_center_x( $e->{i1} );
        my $x2 = $scale->index_to_center_x( $e->{i2} );
        my $y1 = $scale->value_to_y( $e->{p1} );
        my $y2 = $scale->value_to_y( $e->{p2} );

        $canvas->createLine( $x1, $y1, $x2, $y2,
            -fill => C_EQ, -width => 1, -dash => [ 2, 2 ], -tags => [TAG] );

        _tag( $canvas, ( $x1 + $x2 ) / 2, ( $y1 + $y2 ) / 2 - 9,
            $e->{kind}, C_EQ, $placed );
    }
}

# -----------------------------------------------------------------------------
# Eventos Sweep / Grab / Run: marca + etiqueta compacta centrada en la vela
# de resolucion (anti-solape, prioriza los mas recientes).
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    my $start = $#$events - MAX_EVENTS;
    $start = 0 if $start < 0;

    for ( my $k = $#$events ; $k >= $start ; $k-- ) {
        my $ev = $events->[$k];
        my $t  = $ev->{type};
        next if $t eq 'SWEEP' && !$self->{show_sweeps};
        next if $t eq 'GRAB'  && !$self->{show_grabs};
        next if $t eq 'RUN'   && !$self->{show_runs};

        next if $ev->{index} < $off || $ev->{index} > $off + $vb;
        next unless $scale->value_in_range( $ev->{price} );

        my $x = $scale->index_to_center_x( $ev->{index} );
        my $y = $scale->value_to_y( $ev->{price} );
        my $color =
            ( $t eq 'GRAB' ) ? C_GRAB
          : ( $t eq 'RUN' )  ? C_RUN
          : ( $ev->{dir} eq 'up' ) ? C_BSL : C_SSL;

        $canvas->createOval( $x - 3, $y - 3, $x + 3, $y + 3,
            -fill => $color, -outline => $color, -tags => [TAG] );

        my $dy = ( $ev->{dir} eq 'up' ) ? -12 : 12;
        _tag( $canvas, $x, $y + $dy, $ev->{label}, $color, $placed );
    }
}

# -----------------------------------------------------------------------------
# _tag: etiqueta compacta centrada (texto blanco sobre color) anti-solape.
# -----------------------------------------------------------------------------
sub _tag {
    my ( $canvas, $x, $y, $text, $color, $placed ) = @_;

    # Texto primero -> bbox real -> fondo ajustado -> texto al frente. Asi la
    # etiqueta queda exactamente centrada y del tamaño del texto.
    my $t = $canvas->createText(
        $x, $y, -text => $text, -fill => '#ffffff',
        -anchor => 'center', -font => 'TkDefaultFont 8 bold', -tags => [TAG] );
    my @bb = $canvas->bbox($t);
    return 0 unless @bb;
    my ( $x1, $y1, $x2, $y2 ) = @bb;
    my $w = $x2 - $x1;
    my $h = $y2 - $y1;

    for my $p (@$placed) {
        if (   abs( $p->[0] - $x ) < ( $w + $p->[2] ) / 2
            && abs( $p->[1] - $y ) < ( $h + $p->[3] ) / 2 )
        {
            $canvas->delete($t);
            return 0;
        }
    }
    push @$placed, [ $x, $y, $w, $h ];

    my $r = $canvas->createRectangle(
        $x1 - 3, $y1 - 2, $x2 + 3, $y2 + 2,
        -fill => $color, -outline => $color, -tags => [TAG] );
    $canvas->raise( $t, $r );
    return 1;
}

1;
