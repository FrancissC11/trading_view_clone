package Market::Panels::ATRPanel;

# ==============================================================================
# Market::Panels::ATRPanel
# Responsabilidad: Renderizar el indicador ATR en un panel separado
# con su propia escala vertical independiente.
# ==============================================================================

use strict;
use warnings;

my $COLOR_BG      = '#131722';
my $COLOR_ATR     = '#2196f3';   # linea ATR (azul TradingView)
my $COLOR_CROSSH  = '#9598a1';
my $COLOR_VAL_TXT = '#ffffff';
my $COLOR_LBL_TXT = '#2196f3';

# ------------------------------------------------------------------------------
# new
# Inicializa el panel ATR.
# Parametros (hash):
#   canvas   : widget Tk::Canvas
#   canvas_w : ancho del canvas en pixels
#   canvas_h : alto del canvas en pixels
#   scale_w  : ancho de la escala derecha en pixels
# ------------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas   => $args{canvas},
        canvas_w => $args{canvas_w} // 1200,
        canvas_h => $args{canvas_h} // 150,
        scale_w  => $args{scale_w}  // 70,
        scale    => undef,
        _ch_vline => undef,
        _ch_hline => undef,
        _ch_label => undef,
        _ch_box   => undef,
        _last_atr => undef,
    };
    bless $self, $class;
    $self->_init_crosshair();
    return $self;
}

# ------------------------------------------------------------------------------
# _init_crosshair
# Pre-crea los objetos graficos del crosshair del panel ATR.
# Misma estrategia que PricePanel: crear una vez, mover en cada evento.
# ------------------------------------------------------------------------------
sub _init_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    return unless defined $c;

    my $sx = $self->{canvas_w} - $self->{scale_w};

    $self->{_ch_vline} = $c->createLine(
        -1, 0, -1, $self->{canvas_h},
        -fill => $COLOR_CROSSH, -dash => [1, 1], -tags => ['crosshair']
    );
    $self->{_ch_hline} = $c->createLine(
        0, -1, $self->{canvas_w}, -1,
        -fill => $COLOR_CROSSH, -dash => [1, 1], -tags => ['crosshair']
    );
    $self->{_ch_box} = $c->createRectangle(
        $sx, -1, $self->{canvas_w}, -1,
        -fill => $COLOR_CROSSH, -outline => '', -tags => ['crosshair']
    );
    $self->{_ch_label} = $c->createText(
        $sx + 4, -1,
        -text => '', -anchor => 'w',
        -fill => $COLOR_VAL_TXT, -font => ['Courier', 9, 'bold'],
        -tags => ['crosshair']
    );
}

# ------------------------------------------------------------------------------
# get_y_range
# Calcula el rango del ATR visible ignorando undefs del warmup.
# Agrega margen del 20% para que la linea no toque los bordes del panel.
# Parametro $values: arrayref de valores ATR (puede contener undef)
# Retorna: ($y_min, $y_max)
# ------------------------------------------------------------------------------
sub get_y_range {
    my ($self, $values) = @_;
    my @valid = grep { defined $_ } @$values;
    return (0, 1) unless @valid;

    my $min = $valid[0];
    my $max = $valid[0];
    for my $v (@valid) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }
    my $margin = ($max - $min) * 0.20;
    $margin = 0.01 if $margin < 0.001;
    return ($min - $margin, $max + $margin);
}

# ------------------------------------------------------------------------------
# set_scale
# Asigna el objeto Scales al panel.
# Parametro $scale: objeto Market::Panels::Scales
# ------------------------------------------------------------------------------
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# ------------------------------------------------------------------------------
# render
# Dibuja la linea del ATR en el canvas.
# Parametros:
#   $canvas : widget Tk::Canvas
#   $values : arrayref de valores ATR visibles (slice sincronizado con velas)
#   $scale  : objeto Market::Panels::Scales
# ------------------------------------------------------------------------------
sub render {
    my ($self, $canvas, $values, $scale) = @_;

    # FIX: sincronizar escala interna antes de llamar render_last_visible_value
    $self->set_scale($scale);

    $canvas->delete('atr_line');
    $canvas->delete('yscale');
    $canvas->delete('atr_label');
    $canvas->delete('lastatr');

    # Fondo oscuro
    $canvas->createRectangle(
        0, 0, $self->{canvas_w}, $self->{canvas_h},
        -fill => $COLOR_BG, -outline => '', -tags => ['atr_line']
    );

    # Etiqueta del indicador (esquina superior izquierda)
    $canvas->createText(
        6, 6,
        -text   => 'ATR(14)',
        -anchor => 'nw',
        -fill   => $COLOR_LBL_TXT,
        -font   => ['Helvetica', 9, 'bold'],
        -tags   => ['atr_label']
    );

    # Construir polilinea con los puntos validos (saltar undefs del warmup)
    my @points;
    for my $i (0 .. $#$values) {
        next unless defined $values->[$i];
        my $cx = $scale->index_to_center_x($scale->{offset} + $i);
        my $cy = $scale->value_to_y($values->[$i]);
        push @points, $cx, $cy;
    }

    if (@points >= 4) {
        $canvas->createLine(
            @points,
            -fill  => $COLOR_ATR,
            -width => 1.5,
            -tags  => ['atr_line']
        );
    }

    # Guardar ultimo valor ATR valido visible
    my ($last_val) = grep { defined $_ } reverse @$values;
    $self->{_last_atr} = $last_val;

    # Escala derecha Y y etiqueta del ultimo valor
    $scale->_draw_y_scale($canvas, '%.4f', 'yscale');
    $self->render_last_visible_value($canvas);
}

# ------------------------------------------------------------------------------
# render_last_visible_value
# Muestra el ultimo valor ATR valido en la escala derecha.
# ------------------------------------------------------------------------------
sub render_last_visible_value {
    my ($self, $canvas) = @_;
    my $scale = $self->{scale};
    return unless defined $scale && defined $self->{_last_atr};

    $canvas->delete('lastatr');

    my $val   = $self->{_last_atr};
    my $y     = $scale->value_to_y($val);
    my $x     = $scale->_chart_w();
    my $label = sprintf('%.4f', $val);
    my $lw    = length($label) * 7 + 8;

    $canvas->createRectangle(
        $x, $y - 9, $x + $lw, $y + 9,
        -fill => $COLOR_ATR, -outline => '', -tags => ['lastatr']
    );
    $canvas->createText(
        $x + 4, $y,
        -text => $label, -anchor => 'w',
        -fill => $COLOR_VAL_TXT, -font => ['Courier', 9, 'bold'],
        -tags => ['lastatr']
    );
}

# ------------------------------------------------------------------------------
# draw_crosshair
# Mueve el crosshair sincronizado a la posicion del mouse.
# La coordenada X viene del ChartEngine (misma para todos los paneles).
# Parametros: $x, $y coordenadas en pixels de este canvas
# ------------------------------------------------------------------------------
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    return unless defined $c && defined $scale;

    my $w  = $self->{canvas_w};
    my $h  = $self->{canvas_h};
    my $sx = $w - $self->{scale_w};

    $c->coords($self->{_ch_vline}, $x, 0,  $x, $h);
    $c->coords($self->{_ch_hline}, 0,  $y, $w, $y);

    my $val   = $scale->y_to_value($y);
    my $label = sprintf('%.4f', $val);

    $c->coords($self->{_ch_box},   $sx, $y - 9, $w, $y + 9);
    $c->coords($self->{_ch_label}, $sx + 4, $y);
    $c->itemconfigure($self->{_ch_label}, -text => $label);

    $c->raise('crosshair');
}

1;
