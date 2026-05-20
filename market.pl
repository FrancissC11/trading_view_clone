# ==============================================================================
# market.pl
# Punto de entrada del sistema de visualizacion de datos de mercado.
# Clon funcional de TradingView usando Perl/Tk.
#
# Controles:
#   Rueda del mouse     : zoom horizontal
#   Drag boton 1        : scroll horizontal (tiempo)
#   Drag boton derecho  : mover escala Y (modo manual)
#   Doble clic          : restaurar escala automatica
#   Tecla 1             : temporalidad 1 minuto
#   Tecla 5             : temporalidad 5 minutos
#   Tecla f             : temporalidad 15 minutos
#   Tecla r             : reset vista
# ==============================================================================

use strict;
use warnings;

use lib '/home/wesdell/Documentos/trading_view_clone';

use POSIX qw(mktime);
use Tk;
use Tk::Canvas;

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::ChartEngine;

# ------------------------------------------------------------------------------
# CONFIGURACION GENERAL
# ------------------------------------------------------------------------------
my $CANVAS_W     = 1400;
my $PRICE_H      = 450;
my $ATR_H        = 150;
my $SCALE_W      = 75;
my $VISIBLE_BARS = 200;
my $INIT_TF      = 1;

# Buscar el CSV: primero junto al script, luego en subdirectorio data/
my $CSV_FILE = '2026_03.csv';

# ------------------------------------------------------------------------------
# 1. LECTURA Y PARSEO DEL CSV
# ------------------------------------------------------------------------------
print "Cargando datos desde: $CSV_FILE\n";
my $market = Market::MarketData->new();
load_csv($CSV_FILE, $market);
printf "Velas 1m cargadas: %d\n", $market->size();

# ------------------------------------------------------------------------------
# 2. CONSTRUCCION DE TEMPORALIDADES (5m y 15m desde 1m)
# ------------------------------------------------------------------------------
print "Construyendo temporalidades 5m y 15m...\n";
$market->build_timeframes();
$market->set_timeframe($INIT_TF);

# ------------------------------------------------------------------------------
# 3. CALCULO DE INDICADORES (incremental, una vela a la vez)
# ------------------------------------------------------------------------------
print "Calculando ATR(14)...\n";
my $indicators = Market::IndicatorManager->new();
$indicators->register('ATR', Market::Indicators::ATR->new(14));

my $n1m = $market->size();
for (my $i = 0; $i < $n1m; $i++) {
    my $c    = $market->get_candle($i);
    my $fake = bless { _c => $c }, '_FakeMD';
    $indicators->update_last($fake);
}
printf "ATR calculado: %d valores\n", scalar @{ $indicators->get('ATR') };

# ------------------------------------------------------------------------------
# 4. CONSTRUCCION DE LA VENTANA TK
# ------------------------------------------------------------------------------
print "Iniciando interfaz grafica...\n";
my $mw = MainWindow->new();
$mw->title('Market Chart | 1m | NQ Futuros CME - Abril 2026');
$mw->configure(-background => '#131722');
$mw->resizable(1, 1);
$mw->geometry("${CANVAS_W}x" . ($PRICE_H + $ATR_H + 36));

# --- Frame principal ---
my $main_frame = $mw->Frame(-background => '#131722')->pack(
    -fill => 'both', -expand => 1
);

# --- Barra de herramientas ---
my $toolbar = $main_frame->Frame(
    -background => '#1e222d',
    -height     => 30,
)->pack(-side => 'top', -fill => 'x');

# Botones de temporalidad
my @tf_data = ([1, '1m'], [5, '5m'], [15, '15m']);
my @tf_buttons;
for my $tf_entry (@tf_data) {
    my ($tf, $label) = @$tf_entry;
    my $btn = $toolbar->Button(
        -text             => $label,
        -font             => ['Helvetica', 10, 'bold'],
        -background       => '#1e222d',
        -foreground       => '#d1d4dc',
        -activebackground => '#2962ff',
        -activeforeground => '#ffffff',
        -relief           => 'flat',
        -padx             => 12,
        -pady             => 4,
        -command          => sub {},   # se configura despues de crear el engine
    )->pack(-side => 'left', -padx => 2, -pady => 3);
    push @tf_buttons, [$tf, $btn];
}

# Separador visual
$toolbar->Label(
    -text       => '|',
    -foreground => '#2a2e39',
    -background => '#1e222d',
)->pack(-side => 'left', -padx => 4);

# Boton Reset
my $reset_btn = $toolbar->Button(
    -text             => 'Reset',
    -font             => ['Helvetica', 9],
    -background       => '#1e222d',
    -foreground       => '#787b86',
    -activebackground => '#363a45',
    -activeforeground => '#d1d4dc',
    -relief           => 'flat',
    -padx             => 8,
    -command          => sub {},
)->pack(-side => 'left', -padx => 2);

# Etiqueta de ayuda (derecha de la barra)
$toolbar->Label(
    -text       => '  Rueda=zoom  |  Drag=scroll  |  BtnDer=mover Y  |  DblClic=auto Y  |  1/5/F=temporalidad  |  R=reset',
    -foreground => '#4a4e5c',
    -background => '#1e222d',
    -font       => ['Helvetica', 8],
)->pack(-side => 'right', -padx => 8);

# --- Frame de canvases ---
my $chart_frame = $main_frame->Frame(-background => '#131722')->pack(
    -fill => 'both', -expand => 1
);

# Canvas panel de precios (parte superior)
my $price_canvas = $chart_frame->Canvas(
    -width              => $CANVAS_W,
    -height             => $PRICE_H,
    -background         => '#131722',
    -cursor             => 'crosshair',
    -borderwidth        => 0,
    -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# Separador entre paneles
$chart_frame->Frame(
    -background => '#2a2e39',
    -height     => 1,
)->pack(-side => 'top', -fill => 'x');

# Canvas panel ATR (parte inferior)
my $atr_canvas = $chart_frame->Canvas(
    -width              => $CANVAS_W,
    -height             => $ATR_H,
    -background         => '#131722',
    -cursor             => 'crosshair',
    -borderwidth        => 0,
    -highlightthickness => 0,
)->pack(-side => 'top', -fill => 'x');

# ------------------------------------------------------------------------------
# 5. INSTANCIAR CHART ENGINE
# ------------------------------------------------------------------------------
my $engine = Market::ChartEngine->new(
    market       => $market,
    indicators   => $indicators,
    price_canvas => $price_canvas,
    atr_canvas   => $atr_canvas,
    canvas_w     => $CANVAS_W,
    price_h      => $PRICE_H,
    atr_h        => $ATR_H,
    scale_w      => $SCALE_W,
    visible_bars => $VISIBLE_BARS,
);

# Conectar botones de temporalidad al engine
for my $tf_entry (@tf_buttons) {
    my ($tf, $btn) = @$tf_entry;
    $btn->configure(-command => sub {
        $engine->set_timeframe($tf);
        $mw->title("Market Chart | ${tf}m | NQ Futuros CME - Abril 2026");
    });
}
$reset_btn->configure(-command => sub {
    $engine->reset_view();
    $engine->render();
});

# Redimensionado dinamico de la ventana
$price_canvas->bind('<Configure>', sub {
    my $new_w = $price_canvas->width();
    my $new_h = $price_canvas->height();
    return if $new_w < 100 || $new_h < 100;
    $engine->{canvas_w}              = $new_w;
    $engine->{price_h}               = $new_h;
    $engine->{price_panel}{canvas_w} = $new_w;
    $engine->{price_panel}{canvas_h} = $new_h;
    $engine->{atr_panel}{canvas_w}   = $new_w;
    $engine->request_render();
});

$atr_canvas->bind('<Configure>', sub {
    my $new_h = $atr_canvas->height();
    return if $new_h < 30;
    $engine->{atr_h}               = $new_h;
    $engine->{atr_panel}{canvas_h} = $new_h;
    $engine->request_render();
});

# ------------------------------------------------------------------------------
# 6. ENLAZAR EVENTOS Y PRIMER RENDER
# ------------------------------------------------------------------------------
$engine->bind_events();

print "Dibujando chart inicial...\n";
$engine->render();
$price_canvas->focus();

print "Sistema listo.\n";
MainLoop();

# ==============================================================================
# SUBRUTINAS
# ==============================================================================

# load_csv: parsea el CSV OHLCV y carga todas las velas en MarketData
sub load_csv {
    my ($file, $md) = @_;
    open(my $fh, '<', $file) or die "No se puede abrir '$file': $!\n";
    <$fh>;   # saltar header
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my ($time, $open, $high, $low, $close, $vol) = split /,/, $line;
        $md->add_candle({
            time       => $time,
            time_epoch => iso_to_epoch($time),
            open       => $open  + 0,
            high       => $high  + 0,
            low        => $low   + 0,
            close      => $close + 0,
            volume     => $vol   + 0,
        });
    }
    close $fh;
}

# iso_to_epoch: convierte ISO 8601 con offset de zona horaria a Unix epoch UTC
sub iso_to_epoch {
    my ($ts) = @_;
    return 0 unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([+-])(\d{2}):(\d{2})/;
    my ($yr,$mo,$dy,$hr,$mi,$se,$sign,$oh,$om) = ($1,$2,$3,$4,$5,$6,$7,$8,$9);
    local $ENV{TZ} = 'UTC';
    my $epoch  = mktime($se, $mi, $hr, $dy, $mo-1, $yr-1900);
    my $offset = ($oh * 3600 + $om * 60) * ($sign eq '+' ? -1 : 1);
    return $epoch + $offset;
}

# _find_csv: busca el CSV en ubicaciones comunes relativas al script
sub _find_csv {
    my ($base) = @_;
    my @candidates = (
        "$base/2026_03.csv",
        "$base/data/2026_03.csv",
        "$base/../2026_03.csv",
    );
    for my $path (@candidates) {
        return $path if -f $path;
    }
    # Si no se encuentra, usar el primero y dejar que open() falle con mensaje claro
    return $candidates[0];
}

# _FakeMD: objeto minimo para alimentar IndicatorManager::update_last
# durante el calculo inicial (implementa la interfaz last_candle())
package _FakeMD;
sub last_candle { return $_[0]->{_c} }
