# ==============================================================================
# Market::MarketData
# Responsabilidad: Almacenar y gestionar datos de mercado OHLCV.
# Garantiza sincronizacion temporal, acceso eficiente por indice y
# actualizacion incremental de datos.
#
# Temporalidades soportadas: 1m, 5m, 15m
# Dataset: futuros CME, sesion de 23h/dia (17:00-15:59), zona horaria -05:00
# ==============================================================================

package Market::MarketData;

use strict;
use warnings;

# Offset UTC de la zona horaria del dataset (-05:00 = -18000 segundos)
use constant TZ_OFFSET => -18000;

# ------------------------------------------------------------------------------
# new
# Inicializa el almacenamiento de datos OHLC para las tres temporalidades.
# ------------------------------------------------------------------------------
sub new {
    my ($class) = @_;
    my $self = {
        data => {
            1  => [],    # velas de 1 minuto (datos base del CSV)
            5  => [],    # velas de 5 minutos (agregadas desde 1m)
            15 => [],    # velas de 15 minutos (agregadas desde 1m)
        },
        tf => 1,         # temporalidad activa: 1, 5 o 15
    };
    bless $self, $class;
    return $self;
}

# ------------------------------------------------------------------------------
# get_data
# Devuelve la estructura completa de datos (todas las temporalidades).
# Retorna: hashref { 1 => [...], 5 => [...], 15 => [...] }
# ------------------------------------------------------------------------------
sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# ------------------------------------------------------------------------------
# add_candle
# Agrega una vela al array de 1 minuto.
# Parametro $candle: hashref { time, time_epoch, open, high, low, close, volume }
# ------------------------------------------------------------------------------
sub add_candle {
    my ( $self, $candle ) = @_;
    push @{ $self->{data}{1} }, $candle;
}

# ------------------------------------------------------------------------------
# build_tf_candles
# Construye velas agregadas para un timeframe $tf (5 o 15) desde los datos 1m.
# Usa floor al bucket de tiempo para agrupar correctamente en presencia de gaps.
# Parametro $tf: 5 o 15
# ------------------------------------------------------------------------------
sub build_tf_candles {
    my ( $self, $tf ) = @_;

    my $src    = $self->{data}{1};
    my @result = ();
    my $current;

    for my $c (@$src) {
        my $bucket = _floor_to_tf( $c->{time_epoch}, $tf );

        if ( !defined $current || $current->{time_epoch} != $bucket ) {
            push @result, $current if defined $current;
            $current = {
                time       => $c->{time},
                time_epoch => $bucket,
                open       => $c->{open},
                high       => $c->{high},
                low        => $c->{low},
                close      => $c->{close},
                volume     => $c->{volume},
            };
        }
        else {
            $current->{high}   = $c->{high}   if $c->{high} > $current->{high};
            $current->{low}    = $c->{low}    if $c->{low}  < $current->{low};
            $current->{close}  = $c->{close};
            $current->{volume} += $c->{volume};
        }
    }
    push @result, $current if defined $current;
    $self->{data}{$tf} = \@result;
}

# ------------------------------------------------------------------------------
# build_timeframes
# Construye 5m y 15m desde los datos base 1m.
# Llamar despues de cargar todo el CSV.
# ------------------------------------------------------------------------------
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles(5);
    $self->build_tf_candles(15);
}

# ------------------------------------------------------------------------------
# set_timeframe
# Selecciona la temporalidad activa. Afecta todos los metodos publicos.
# Parametro $tf: 1, 5 o 15
# ------------------------------------------------------------------------------
sub set_timeframe {
    my ( $self, $tf ) = @_;
    die "Temporalidad invalida: $tf\n" unless exists $self->{data}{$tf};
    $self->{tf} = $tf;
}

# ------------------------------------------------------------------------------
# _active_array  (privado)
# Devuelve la referencia al array activo segun el timeframe configurado.
# ------------------------------------------------------------------------------
sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{tf} };
}

# ------------------------------------------------------------------------------
# get_slice
# Devuelve las velas entre los indices $start y $end inclusive.
# Aplica clamping automatico para no salirse del rango.
# Retorna: lista de hashrefs de velas
# ------------------------------------------------------------------------------
sub get_slice {
    my ( $self, $start, $end ) = @_;
    my $arr = $self->_active_array();
    my $n   = scalar @$arr;
    $start = 0      if $start < 0;
    $end   = $n - 1 if $end >= $n;
    return () if $start > $end;
    return @{$arr}[ $start .. $end ];
}

# ------------------------------------------------------------------------------
# get_candle
# Obtiene una vela por indice absoluto. Retorna undef si esta fuera de rango.
# ------------------------------------------------------------------------------
sub get_candle {
    my ( $self, $index ) = @_;
    my $arr = $self->_active_array();
    return undef if $index < 0 || $index >= scalar @$arr;
    return $arr->[$index];
}

# ------------------------------------------------------------------------------
# size
# Numero total de velas en la temporalidad activa.
# ------------------------------------------------------------------------------
sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array() };
}

# ------------------------------------------------------------------------------
# last_candle
# Devuelve la ultima vela de la temporalidad activa.
# ------------------------------------------------------------------------------
sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return undef unless @$arr;
    return $arr->[-1];
}

# ------------------------------------------------------------------------------
# last_index
# Devuelve el indice de la ultima vela (size - 1).
# ------------------------------------------------------------------------------
sub last_index {
    my ($self) = @_;
    return $self->size() - 1;
}

# ------------------------------------------------------------------------------
# get_timestamp
# Obtiene el epoch Unix de la vela en la posicion $index.
# ------------------------------------------------------------------------------
sub get_timestamp {
    my ( $self, $index ) = @_;
    my $c = $self->get_candle($index);
    return undef unless defined $c;
    return $c->{time_epoch};
}

# ------------------------------------------------------------------------------
# merge_delta_row
# Actualiza o inserta datos incrementales (streaming en tiempo real).
# Si el epoch coincide con la ultima vela 1m, la actualiza (in-place).
# Si el epoch es nuevo, inserta una vela nueva y propaga a TFs superiores.
# Parametro $row: hashref { time, time_epoch, open, high, low, close, volume }
# ------------------------------------------------------------------------------
sub merge_delta_row {
    my ( $self, $row ) = @_;
    my $arr1 = $self->{data}{1};

    if ( @$arr1 && $arr1->[-1]{time_epoch} == $row->{time_epoch} ) {
        # Actualizar ultima vela in-place
        my $last = $arr1->[-1];
        $last->{high}   = $row->{high}  if $row->{high}  > $last->{high};
        $last->{low}    = $row->{low}   if $row->{low}   < $last->{low};
        $last->{close}  = $row->{close};
        $last->{volume} = $row->{volume};
    }
    else {
        $self->add_candle($row);
    }
}

# ------------------------------------------------------------------------------
# compute_time_anchors
# Calcula los indices donde deben aparecer etiquetas en el eje X de tiempo.
# Detecta cambios de hora LOCAL (ajustado por TZ_OFFSET) para evitar
# desfases entre la hora mostrada y las etiquetas del eje.
#
# Para 1m : etiqueta en cada cambio de hora local
# Para 5m : etiqueta cada 2 horas locales
# Para 15m: etiqueta cada 4 horas locales
#
# Retorna: arrayref de indices dentro del array activo
# ------------------------------------------------------------------------------
sub compute_time_anchors {
    my ($self) = @_;
    my $arr    = $self->_active_array();
    my $n      = scalar @$arr;
    my @anchors;

    # Intervalo de horas entre etiquetas segun temporalidad
    my $hour_step =
        $self->{tf} == 1  ? 1
      : $self->{tf} == 5  ? 2
      :                     4;    # 15m

    my $last_anchor_hour = -1;

    for ( my $i = 0 ; $i < $n ; $i++ ) {
        my $epoch = $arr->[$i]{time_epoch};

        # Convertir a hora LOCAL antes de calcular el bucket de hora
        my $local_epoch = $epoch + TZ_OFFSET;
        my $hour        = int( $local_epoch / 3600 ) % 24;

        if ( $hour % $hour_step == 0 && $hour != $last_anchor_hour ) {
            push @anchors, $i;
            $last_anchor_hour = $hour;
        }
    }

    return \@anchors;
}

# ==============================================================================
# FUNCIONES PRIVADAS
# ==============================================================================

# _floor_to_tf: redondea un epoch Unix al inicio del bucket de $tf minutos
sub _floor_to_tf {
    my ( $epoch, $tf ) = @_;
    my $secs = $tf * 60;
    return int( $epoch / $secs ) * $secs;
}

1;
