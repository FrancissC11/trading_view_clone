package Market::Overlays::SMC_Structures;

# =============================================================================
# Market::Overlays::SMC_Structures   (Tabla 1 del PDF)
#
# Renderizado en el Canvas de las estructuras SMC ya calculadas por
# Indicators/SMC_Structures.pm: zonas FVG con desvanecimiento progresivo y
# etiquetas BOS / CHoCH ubicadas en el tiempo. NO calcula nada.
#
# Contrato de Overlay (OverlayManager): tag() + render($canvas, $scale).
# Reutiliza el MISMO objeto Scales del panel de precio.
# Sub-toggles independientes: show_fvg / show_bos / show_choch.
#
# Las etiquetas se dibujan como "tags" compactos centrados (texto blanco sobre
# fondo de color), con anti-solapamiento para que no se amontonen.
# =============================================================================

use strict;
use warnings;
use POSIX qw(floor);

use constant TAG => 'overlay_smc';

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},
        max_age    => $args{max_age} // 50,
        show_fvg   => $args{show_fvg}   // 1,
        show_bos   => $args{show_bos}   // 1,
        show_choch => $args{show_choch} // 1,
    };
    bless $self, $class;
    return $self;
}

sub tag { return TAG; }

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# -----------------------------------------------------------------------------
# render: se auto-limpia con su tag y dibuja solo lo visible.
# -----------------------------------------------------------------------------
sub render {
    my ( $self, $canvas, $scale ) = @_;
    $canvas->delete(TAG);
    my $src = $self->{source};
    return unless $src;

    my @placed;   # cajas de etiquetas ya colocadas (anti-solape)
    $self->_render_fvgs( $canvas, $scale, $src, \@placed ) if $self->{show_fvg};
    $self->_render_events( $canvas, $scale, $src, \@placed )
        if $self->{show_bos} || $self->{show_choch};
}

# -----------------------------------------------------------------------------
# FVG con desvanecimiento progresivo (interpolacion de color hacia blanco
# segun la edad en velas). La edad depende de processed_last (replay-aware).
# -----------------------------------------------------------------------------
sub _render_fvgs {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $fvgs = $src->get_fvgs or return;
    my $last_known = $src->processed_last;
    my $max_age    = $self->{max_age};

    my $off    = $scale->{offset};
    my $vb     = $scale->{visible_bars};
    my $plot_w = $scale->_plot_w;

    for my $f (@$fvgs) {
        next if $f->{state} eq 'expired';

        my $age = $last_known - $f->{created};
        next if $age > $max_age;

        my $right_idx = ( $f->{state} eq 'mitigated' && defined $f->{mitig_at} )
            ? $f->{mitig_at}
            : $f->{created} + $max_age;
        $right_idx = $last_known if $right_idx > $last_known;

        next if $right_idx      < $off;
        next if $f->{idx_start} > $off + $vb;
        next unless $scale->value_in_range( $f->{top} )
                 || $scale->value_in_range( $f->{bottom} )
                 || ( $f->{bottom} < $scale->{min_val}
                   && $f->{top}    > $scale->{max_val} );

        my $opacity = 1 - ( $age / $max_age );
        $opacity = 0.10 if $opacity < 0.10;
        $opacity *= 0.5 if $f->{state} eq 'mitigated';

        my $base = ( $f->{dir} eq 'bull' ) ? '#26a69a' : '#ef5350';
        my $fill = _fade( $base, $opacity * 0.55 );   # relleno suave

        my $x1 = $scale->index_to_center_x( $f->{idx_start} );
        my $x2 = $scale->index_to_center_x($right_idx);
        $x1 = 0       if $x1 < 0;
        $x2 = $plot_w if $x2 > $plot_w;
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $f->{top} );
        my $yb = $scale->value_to_y( $f->{bottom} );

        $canvas->createRectangle(
            $x1, $yt, $x2, $yb,
            -fill    => $fill,
            -outline => _fade( $base, $opacity ),
            -width   => 1,
            -tags    => [TAG],
        );

        # Etiqueta compacta solo en FVG fresco y si hay espacio (anti-solape).
        if ( $age <= int( $max_age / 3 ) && ( $yb - $yt ) >= 12 ) {
            _tag( $canvas, $x1 + 16, ( $yt + $yb ) / 2, 'FVG',
                _fade( $base, 1 ), $placed );
        }
    }
}

# -----------------------------------------------------------------------------
# Etiquetas BOS / CHoCH ancladas a la vela exacta del evento, centradas.
# -----------------------------------------------------------------------------
sub _render_events {
    my ( $self, $canvas, $scale, $src, $placed ) = @_;
    my $events = $src->get_events or return;

    my $off = $scale->{offset};
    my $vb  = $scale->{visible_bars};

    # De mas reciente a mas antiguo: prioriza etiquetas nuevas si hay solape.
    for ( my $k = $#$events ; $k >= 0 ; $k-- ) {
        my $e = $events->[$k];
        next if $e->{type} eq 'BOS'   && !$self->{show_bos};
        next if $e->{type} eq 'CHoCH' && !$self->{show_choch};

        next if $e->{index} < $off || $e->{index} > $off + $vb;
        next unless $scale->value_in_range( $e->{price} );

        my $x = $scale->index_to_center_x( $e->{index} );
        my $y = $scale->value_to_y( $e->{price} );
        my $color = ( $e->{type} eq 'BOS' ) ? '#2962ff' : '#ff6d00';

        # Linea de nivel roto y etiqueta arriba (alcista) / abajo (bajista).
        $canvas->createLine( $x - 18, $y, $x + 18, $y,
            -fill => $color, -dash => [ 4, 3 ], -width => 1, -tags => [TAG] );
        my $dy = ( $e->{dir} eq 'up' ) ? -12 : 12;
        _tag( $canvas, $x, $y + $dy, $e->{label}, $color, $placed );
    }
}

# -----------------------------------------------------------------------------
# _tag: etiqueta compacta centrada (texto blanco sobre fondo de color) con
# anti-solapamiento. $placed acumula [cx,cy,w,h] de las ya dibujadas.
# Devuelve 1 si la dibujo, 0 si la omitio por solape.
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

# -----------------------------------------------------------------------------
# _fade: mezcla un color hex con blanco segun opacidad [0..1].
# -----------------------------------------------------------------------------
sub _fade {
    my ( $hex, $opacity ) = @_;
    $opacity = 0 if $opacity < 0;
    $opacity = 1 if $opacity > 1;
    my ( $r, $g, $b ) = ( hex( substr( $hex, 1, 2 ) ),
                          hex( substr( $hex, 3, 2 ) ),
                          hex( substr( $hex, 5, 2 ) ) );
    my $f = 1 - $opacity;
    $r = int( $r + ( 255 - $r ) * $f );
    $g = int( $g + ( 255 - $g ) * $f );
    $b = int( $b + ( 255 - $b ) * $f );
    return sprintf( '#%02x%02x%02x', $r, $g, $b );
}

1;
