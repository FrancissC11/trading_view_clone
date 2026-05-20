package Market::ChartEngine;

# ==============================================================================
# Market::ChartEngine
# Responsabilidad: Motor principal del grafico. Orquesta el renderizado
# completo del sistema. Coordina paneles, escalas y eventos del usuario.
#
# Estado interno:
#   visible_bars : cuantas velas caben en pantalla (zoom horizontal)
#   offset       : indice de la primera vela visible (scroll)
#   crosshair_x/y: posicion actual del mouse
#   y_min/y_max  : rango vertical manual (cuando auto_scale=0)
#   auto_scale   : 1=escalado Y automatico, 0=manual
# ==============================================================================

use strict;
use warnings;

use lib '/home/wesdell/Documentos/trading_view_clone';
use POSIX qw(floor ceil);

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

# Limites de zoom horizontal (velas visibles en pantalla)
my $MIN_BARS = 10;
my $MAX_BARS = 500;

# ------------------------------------------------------------------------------
# new
# Inicializa el motor del grafico.
# Parametros (hash):
#   market       : objeto Market::MarketData
#   indicators   : objeto Market::IndicatorManager
#   price_canvas : Tk::Canvas del panel superior (velas)
#   atr_canvas   : Tk::Canvas del panel inferior (ATR)
#   canvas_w     : ancho de los canvases en pixels
#   price_h      : alto del canvas de precios en pixels
#   atr_h        : alto del canvas del ATR en pixels
#   scale_w      : ancho de la escala derecha en pixels
#   visible_bars : velas visibles iniciales
# ------------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;

    my $self = {
        market       => $args{market},
        indicators   => $args{indicators},
        price_canvas => $args{price_canvas},
        atr_canvas   => $args{atr_canvas},
        canvas_w     => $args{canvas_w}     // 1200,
        price_h      => $args{price_h}      // 400,
        atr_h        => $args{atr_h}        // 150,
        scale_w      => $args{scale_w}      // 70,

        # Estado de la vista
        visible_bars => $args{visible_bars} // 200,
        offset       => 0,
        auto_scale   => 1,
        y_min        => undef,
        y_max        => undef,
        y_atr_min    => undef,
        y_atr_max    => undef,

        # Crosshair
        crosshair_x     => undef,
        crosshair_y     => undef,
        crosshair_panel => 'price',

        # Render diferido
        _render_pending => 0,

        # Drag horizontal
        _drag_start_x => undef,
        _drag_offset  => undef,

        # Drag vertical (escala Y manual)
        _drag_start_y => undef,
        _drag_y_min   => undef,
        _drag_y_max   => undef,
    };

    bless $self, $class;

    # Instanciar paneles
    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas   => $self->{price_canvas},
        canvas_w => $self->{canvas_w},
        canvas_h => $self->{price_h},
        scale_w  => $self->{scale_w},
    );
    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas   => $self->{atr_canvas},
        canvas_w => $self->{canvas_w},
        canvas_h => $self->{atr_h},
        scale_w  => $self->{scale_w},
    );

    # Posicionar vista al final del dataset
    $self->reset_view();

    return $self;
}

# ------------------------------------------------------------------------------
# compute_window
# Calcula que porcion de datos es visible en pantalla.
# Retorna: ($start, $end) indices de la ventana visible
# ------------------------------------------------------------------------------
sub compute_window {
    my ($self) = @_;
    my $total = $self->{market}->size();
    my $end   = $self->{offset} + $self->{visible_bars} - 1;
    $end      = $total - 1 if $end >= $total;
    my $start = $end - $self->{visible_bars} + 1;
    $start    = 0 if $start < 0;
    return ($start, $end);
}

# ------------------------------------------------------------------------------
# round
# Redondeo auxiliar al entero mas cercano.
# ------------------------------------------------------------------------------
sub round {
    my ($self, $value) = @_;
    return int($value + 0.5);
}

# ------------------------------------------------------------------------------
# request_render
# Solicita un render diferido usando 'after' de Tk (~60fps).
# Evita renders redundantes si multiples eventos llegan en el mismo frame.
# ------------------------------------------------------------------------------
sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    $self->{price_canvas}->after(16, sub {
        $self->{_render_pending} = 0;
        $self->render();
    });
}

# ------------------------------------------------------------------------------
# render
# Dibuja todo el grafico: velas + ATR + escalas + crosshair.
# Loop de render principal: calcula ventana, construye escalas, llama paneles.
# ------------------------------------------------------------------------------
sub render {
    my ($self) = @_;

    my ($start, $end) = $self->compute_window();
    return if $start > $end;

    my @candles   = $self->{market}->get_slice($start, $end);
    return unless @candles;

    my @atr_slice = $self->{indicators}->slice_array('ATR', $start, $end);

    # Argumentos de escala X compartidos entre paneles
    my %scale_x = (
        canvas_w     => $self->{canvas_w},
        scale_w      => $self->{scale_w},
        visible_bars => $self->{visible_bars},
        offset       => $start,
    );

    # ---- Escala Y del panel de precios ----
    my ($y_min, $y_max);
    if ($self->{auto_scale}) {
        ($y_min, $y_max) = $self->{price_panel}->get_y_range(\@candles);
    }
    else {
        $y_min = $self->{y_min};
        $y_max = $self->{y_max};
    }

    my $price_scale = Market::Panels::Scales->new(
        %scale_x,
        canvas_h    => $self->{price_h},
        y_min       => $y_min,
        y_max       => $y_max,
        padding_top => 10,
        padding_bot => 25,
    );

    # Render panel de precios
    $self->{price_panel}->render($self->{price_canvas}, \@candles, $price_scale);

    # Eje de tiempo
    my $labels = $self->compute_intraday_labels();
    $self->{price_panel}->draw_time_axis($self->{price_canvas}, $labels);

    # ---- Escala Y del panel ATR (independiente) ----
    my ($ya_min, $ya_max);
    if ($self->{auto_scale} || !defined $self->{y_atr_min}) {
        ($ya_min, $ya_max) = $self->{atr_panel}->get_y_range(\@atr_slice);
    }
    else {
        $ya_min = $self->{y_atr_min};
        $ya_max = $self->{y_atr_max};
    }

    my $atr_scale = Market::Panels::Scales->new(
        %scale_x,
        canvas_h    => $self->{atr_h},
        y_min       => $ya_min,
        y_max       => $ya_max,
        padding_top => 10,
        padding_bot => 10,
    );

    # Render panel ATR
    $self->{atr_panel}->render($self->{atr_canvas}, \@atr_slice, $atr_scale);

    # Crosshair (si el mouse esta dentro del grafico)
    if (defined $self->{crosshair_x}) {
        $self->_draw_crosshair_all();
    }
}

# ------------------------------------------------------------------------------
# _bind_all_canvas
# Asocia un evento a multiples canvases con el mismo callback.
# Parametros: $event (string Tk), $callback (subrutina)
# ------------------------------------------------------------------------------
sub _bind_all_canvas {
    my ($self, $event, $callback) = @_;
    $self->{price_canvas}->bind($event, $callback);
    $self->{atr_canvas}->bind($event, $callback);
}

# ------------------------------------------------------------------------------
# bind_events
# Registra todos los eventos de mouse y teclado.
# FIX: usa $canvas->XEvent->x/y/D (sintaxis correcta de Perl/Tk)
#      En Perl/Tk NO existe Tk::event->x -- eso es sintaxis de Python/Tkinter.
# ------------------------------------------------------------------------------
sub bind_events {
    my ($self) = @_;
    my $pc = $self->{price_canvas};
    my $ac = $self->{atr_canvas};

    # --- Movimiento del mouse: actualiza crosshair en ambos paneles ---
    $pc->bind('<Motion>', sub {
        my $e = $pc->XEvent;
        $self->_on_mouse_move($e->x, $e->y, 'price');
    });
    $ac->bind('<Motion>', sub {
        my $e = $ac->XEvent;
        $self->_on_mouse_move($e->x, $e->y, 'atr');
    });

    # Ocultar crosshair al salir del canvas
    $pc->bind('<Leave>', sub { $self->{crosshair_x} = undef; $self->request_render() });
    $ac->bind('<Leave>', sub { $self->{crosshair_x} = undef; $self->request_render() });

    # --- Zoom horizontal con rueda del mouse ---
    for my $cv ($pc, $ac) {
        # Linux: Button-4 (arriba) y Button-5 (abajo)
        $cv->bind('<Button-4>', sub { $self->_horizontal_zoom(-1) });
        $cv->bind('<Button-5>', sub { $self->_horizontal_zoom( 1) });
        # Windows/Mac: MouseWheel con delta D
        $cv->bind('<MouseWheel>', sub {
            my $d = $cv->XEvent->D;
            $self->_horizontal_zoom(-$d / 120);
        });
    }

    # --- Drag horizontal (scroll de tiempo): boton 1 ---
    for my $cv ($pc, $ac) {
        $cv->bind('<ButtonPress-1>', sub {
            my $e = $cv->XEvent;
            $self->{_drag_start_x} = $e->x;
            $self->{_drag_offset}  = $self->{offset};
        });
        $cv->bind('<B1-Motion>', sub {
            my $e  = $cv->XEvent;
            my $dx = $e->x - $self->{_drag_start_x};
            $self->_on_drag_horizontal($dx);
        });
        $cv->bind('<ButtonRelease-1>', sub {
            $self->{_drag_start_x} = undef;
        });
    }

    # --- Drag vertical en panel de precios: boton derecho ---
    # FIX: capturar y_min/y_max actuales de la escala al iniciar el drag,
    #      ya que pueden ser undef si auto_scale estaba activo.
    $pc->bind('<ButtonPress-3>', sub {
        my $e         = $pc->XEvent;
        my $cur_scale = $self->{price_panel}{scale};
        if ($self->{auto_scale} && defined $cur_scale) {
            # Congelar el rango actual antes de desactivar auto_scale
            $self->{y_min} = $cur_scale->{y_min};
            $self->{y_max} = $cur_scale->{y_max};
        }
        $self->{auto_scale}    = 0;
        $self->{_drag_start_y} = $e->y;
        $self->{_drag_y_min}   = $self->{y_min};
        $self->{_drag_y_max}   = $self->{y_max};
    });
    $pc->bind('<B3-Motion>', sub {
        my $e  = $pc->XEvent;
        my $dy = $e->y - $self->{_drag_start_y};
        $self->_vertical_drag($dy);
    });
    $pc->bind('<ButtonRelease-3>', sub {
        $self->{_drag_start_y} = undef;
    });

    # --- Doble click izquierdo: restaurar escala automatica ---
    $pc->bind('<Double-Button-1>', sub {
        $self->{auto_scale} = 1;
        $self->request_render();
    });

    # --- Teclas de temporalidad (requiere focus en el canvas) ---
    $pc->bind('<Key-1>', sub { $self->set_timeframe(1)  });
    $pc->bind('<Key-5>', sub { $self->set_timeframe(5)  });
    $pc->bind('<Key-f>', sub { $self->set_timeframe(15) });
    $pc->bind('<Key-r>', sub { $self->reset_view(); $self->render() });

    $pc->focus();
}

# ------------------------------------------------------------------------------
# _horizontal_zoom
# Controla el zoom horizontal modificando visible_bars.
# $delta > 0: alejar (mas velas visibles), $delta < 0: acercar (menos velas).
# ------------------------------------------------------------------------------
sub _horizontal_zoom {
    my ($self, $delta) = @_;
    my $factor   = ($delta > 0) ? 1.10 : 0.90;
    my $new_bars = int($self->{visible_bars} * $factor + 0.5);
    $new_bars    = $MIN_BARS if $new_bars < $MIN_BARS;
    $new_bars    = $MAX_BARS if $new_bars > $MAX_BARS;
    $self->{visible_bars} = $new_bars;
    $self->_clamp_offset();
    $self->request_render();
}

# ------------------------------------------------------------------------------
# _on_drag_horizontal  (privado)
# Desplaza el grafico horizontalmente al arrastrar con el mouse.
# $dx: diferencia de pixels desde el inicio del drag (positivo = derecha)
# ------------------------------------------------------------------------------
sub _on_drag_horizontal {
    my ($self, $dx) = @_;
    return unless defined $self->{_drag_start_x};

    my $bar_w      = ($self->{canvas_w} - $self->{scale_w}) / $self->{visible_bars};
    my $delta_bars = int(-$dx / $bar_w);
    $self->{offset} = $self->{_drag_offset} + $delta_bars;
    $self->_clamp_offset();
    $self->request_render();
}

# ------------------------------------------------------------------------------
# _vertical_drag
# Desplaza el rango Y verticalmente (modo manual, boton derecho).
# $dy: diferencia de pixels desde el inicio del drag
# ------------------------------------------------------------------------------
sub _vertical_drag {
    my ($self, $dy) = @_;
    return unless defined $self->{_drag_start_y};

    my $y_min = $self->{_drag_y_min} // 0;
    my $y_max = $self->{_drag_y_max} // 0;
    my $range = $y_max - $y_min;
    return if $range <= 0;

    my $pixels_h = $self->{price_h} - 35;
    return if $pixels_h <= 0;

    my $delta_v = $dy / $pixels_h * $range;
    $self->{y_min} = $y_min + $delta_v;
    $self->{y_max} = $y_max + $delta_v;
    $self->request_render();
}

# ------------------------------------------------------------------------------
# _vertical_zoom
# Expande o contrae el rango Y alrededor del centro visible.
# $factor: >1 expande el rango, <1 lo contrae
# ------------------------------------------------------------------------------
sub _vertical_zoom {
    my ($self, $factor) = @_;
    $self->{auto_scale} = 0;
    my $scale = $self->{price_panel}{scale};
    return unless defined $scale;

    my $mid  = ($scale->{y_max} + $scale->{y_min}) / 2.0;
    my $half = ($scale->{y_max} - $scale->{y_min}) / 2.0 * $factor;
    $self->{y_min} = $mid - $half;
    $self->{y_max} = $mid + $half;
    $self->request_render();
}

# ------------------------------------------------------------------------------
# _on_mouse_move
# Actualiza la posicion del crosshair y redibuja.
# $panel: 'price' | 'atr' (indica en que canvas esta el mouse)
# ------------------------------------------------------------------------------
sub _on_mouse_move {
    my ($self, $x, $y, $panel) = @_;
    $self->{crosshair_x}     = $x;
    $self->{crosshair_y}     = $y;
    $self->{crosshair_panel} = $panel;
    $self->_draw_crosshair_all();
}

# ------------------------------------------------------------------------------
# _draw_crosshair_all
# Dibuja el crosshair sincronizado en todos los paneles.
# La X es identica en ambos paneles (eje de tiempo compartido).
# La Y es independiente: solo el panel activo muestra la linea horizontal real.
# ------------------------------------------------------------------------------
sub _draw_crosshair_all {
    my ($self) = @_;
    my $x = $self->{crosshair_x};
    return unless defined $x;

    my $panel = $self->{crosshair_panel} // 'price';
    my $y     = $self->{crosshair_y}     // 0;

    # Panel de precios: Y real si el mouse esta aqui, centrado si no
    my $price_y = ($panel eq 'price') ? $y : int($self->{price_h} / 2);
    $self->{price_panel}->draw_crosshair($x, $price_y);

    # Panel ATR: Y real si el mouse esta aqui, centrado si no
    my $atr_y = ($panel eq 'atr') ? $y : int($self->{atr_h} / 2);
    $self->{atr_panel}->draw_crosshair($x, $atr_y);
}

# ------------------------------------------------------------------------------
# set_timeframe
# Cambia la temporalidad y recalcula todos los indicadores desde cero.
# Parametro $tf: 1, 5 o 15
# ------------------------------------------------------------------------------
sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{market}->set_timeframe($tf);
    $self->{indicators}->reset_all();

    # Recalcular indicadores para todas las velas del nuevo timeframe
    my $n = $self->{market}->size();
    for (my $i = 0; $i < $n; $i++) {
        my $c      = $self->{market}->get_candle($i);
        my $fake   = bless { _c => $c }, '_SingleCandle';
        $self->{indicators}->update_last($fake);
    }

    $self->reset_view();
    $self->request_render();
}

# ------------------------------------------------------------------------------
# reset_view
# Resetea zoom y desplazamiento: muestra las ultimas visible_bars velas.
# ------------------------------------------------------------------------------
sub reset_view {
    my ($self) = @_;
    my $total = $self->{market}->size();
    $self->{offset} = ($total > $self->{visible_bars})
                      ? $total - $self->{visible_bars} : 0;
    $self->{auto_scale} = 1;
    $self->{y_min}      = undef;
    $self->{y_max}      = undef;
}

# ------------------------------------------------------------------------------
# compute_intraday_labels
# Calcula etiquetas de tiempo visibles para el eje X.
# Espaciado minimo de 60px entre etiquetas para evitar solapamiento.
# Retorna: arrayref de hashrefs { idx => $i, label => $string }
# ------------------------------------------------------------------------------
sub compute_intraday_labels {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my @labels;

    my $min_px = 60;
    my $bar_w  = ($self->{canvas_w} - $self->{scale_w}) / $self->{visible_bars};
    my $step   = ($bar_w > 0) ? int($min_px / $bar_w) + 1 : 1;

    my $prev_label = '';
    for (my $i = $start; $i <= $end; $i += $step) {
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;

        my $label = _format_time_label($ts, $self->{market}{tf});
        next if $label eq $prev_label;
        $prev_label = $label;

        push @labels, { idx => $i, label => $label };
    }
    return \@labels;
}

# ------------------------------------------------------------------------------
# get_all_timestamps
# Devuelve los epochs Unix de todas las velas actualmente visibles.
# Util para sincronizacion entre paneles.
# Retorna: arrayref de enteros (Unix epoch)
# ------------------------------------------------------------------------------
sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    my @ts;
    for my $i ($start .. $end) {
        my $t = $self->{market}->get_timestamp($i);
        push @ts, $t if defined $t;
    }
    return \@ts;
}

# ==============================================================================
# HELPERS PRIVADOS
# ==============================================================================

# _clamp_offset: mantiene el offset dentro del rango valido del dataset
sub _clamp_offset {
    my ($self) = @_;
    my $total = $self->{market}->size();
    $self->{offset} = 0          if $self->{offset} < 0;
    $self->{offset} = $total - 1 if $self->{offset} > $total - 1;
}

# _format_time_label: formatea un epoch UTC como etiqueta legible (UTC-5)
sub _format_time_label {
    my ($epoch, $tf) = @_;
    my @t = gmtime($epoch - 5 * 3600);   # ajuste a UTC-5
    if ($tf == 15) {
        return sprintf('%02d/%02d %02d:%02d', $t[4]+1, $t[3], $t[2], $t[1]);
    }
    return sprintf('%02d:%02d', $t[2], $t[1]);
}

# _SingleCandle: objeto minimo que implementa last_candle() para update_last
package _SingleCandle;
sub last_candle { return $_[0]->{_c} }

1;
