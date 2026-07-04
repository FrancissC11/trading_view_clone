use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use lib "$FindBin::Bin/Market";
use lib ".";

use Tk;
use sml;
use Time::Piece;

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::ChartEngine;
use Market::Debug::LiquidityDebug;

my $csv = $ARGV[0] || "$FindBin::Bin/2026_03.csv";
print "Cargando datos desde '$csv'...\n";

my $dataset = sml->load_csv($csv);

my $market = Market::MarketData->new();

for my $row (@$dataset) {
    my $time = $row->[0];
    $time =~ s/\.\d+//;

    my $clean = $time;
    $clean =~ s/[-+]\d\d:\d\d$//;

    my $epoch = Time::Piece->strptime(
        $clean,
        '%Y-%m-%dT%H:%M:%S'
    )->epoch;

    $market->add_candle({
        time   => $time,
        epoch  => $epoch,
        open   => $row->[1] + 0,
        high   => $row->[2] + 0,
        low    => $row->[3] + 0,
        close  => $row->[4] + 0,
        volume => $row->[5] + 0,
    });
}

$market->build_timeframes();
$market->set_timeframe(1);

print "Datos cargados: ", $market->size(), " velas de 1 minuto.\n";

my $indicators = Market::IndicatorManager->new();
$indicators->register(
    'ATR',
    Market::Indicators::ATR->new(period => 14)
);

$indicators->update_last($market);

my $atr_values = $indicators->get('ATR');

my $liquidity = Market::Indicators::Liquidity->new(
    atr_mult       => 4.0,
    minor_atr_mult => 1.5,
    confirm_bars   => 3,
);

my $liq_result = $liquidity->calculate_until(
    $market->get_slice(0, $market->last_index()),
    $atr_values,
    $market->last_index()
);


for my $lvl (@{$liq_result->{liquidity}}){

    next unless defined $lvl->{classification};

    #next unless $lvl->{classification} eq 'Sweep';
    #next unless $lvl->{classification} eq 'Grab';
    next unless $lvl->{classification} eq 'Run';
    Market::Debug::LiquidityDebug::audit(

        candles => $market->get_slice(
            0,
            $market->last_index()
        ),

        level => $lvl

    );

    last;
}



my $smc = Market::Indicators::SMC_Structures->new(
    choch_atr_mult => 2.0,
);

my $smc_result = $smc->calculate(
    $liq_result->{structural_pivots}
);

print "\n=== PRUEBA LIQUIDITY ===\n";
print "Pivots detectados: " . scalar(@{$liq_result->{pivots}}) . "\n";
print "Liquidity levels: " . scalar(@{$liq_result->{liquidity}}) . "\n";
my %liq_state_count;
my %liq_class_count;

for my $lvl (@{$liq_result->{liquidity}}) {
    $liq_state_count{$lvl->{state}}++;

    if (defined $lvl->{classification}) {
        $liq_class_count{$lvl->{classification}}++;
    }
}

print "Liquidity states:\n";
for my $k (sort keys %liq_state_count) {
    print "  $k => $liq_state_count{$k}\n";
}

print "Liquidity classifications:\n";
for my $k (sort keys %liq_class_count) {
    print "  $k => $liq_class_count{$k}\n";
}
print "Minor pivots: " . scalar(@{$liq_result->{minor_pivots}}) . "\n";
print "Structural pivots: " . scalar(@{$liq_result->{structural_pivots}}) . "\n";
print "Equal levels: " . scalar(@{$liq_result->{equal_levels} || []}) . "\n";

for my $eq (@{$liq_result->{equal_levels} || []}[0 .. 10]) {
    next if !$eq;

    printf "%s i1=%d i2=%d price=%.2f tolerance=%.4f\n",
        $eq->{type},
        $eq->{index1},
        $eq->{index2},
        $eq->{price},
        $eq->{tolerance};
}

my %eq_count;

for my $eq (@{$liq_result->{equal_levels} || []}) {
    $eq_count{$eq->{type}}++;
}

for my $k (sort keys %eq_count) {
    print "$k => $eq_count{$k}\n";
}
print "========================\n\n";

print "\n=== PRUEBA SMC STRUCTURE ===\n";
print "Structure points: " . scalar(@{$smc_result->{structure}}) . "\n";

for my $s (@{$smc_result->{structure}}[0 .. 20]) {
    next if !$s;
    printf "%s %s i=%d price=%.2f\n",
        $s->{type}, $s->{label}, $s->{index}, $s->{price};
}

print "============================\n\n";

print "\n=== PRUEBA BOS / CHoCH ===\n";
print "Eventos: " . scalar(@{$smc_result->{events}}) . "\n";

my $last_event;

for my $e (@{$smc_result->{events}}) {
    if (defined $last_event) {
        my $distance = $e->{index} - $last_event->{index};

        printf "DIST=%d %s -> %s\n",
            $distance,
            $last_event->{type},
            $e->{type};
    }

    $last_event = $e;
}

for my $e (@{$smc_result->{events}}[0 .. 20]) {
    next if !$e;
    printf "%s i=%d price=%.2f pivot=%s\n",
        $e->{type}, $e->{index}, $e->{price}, $e->{pivot};
}

print "==========================\n\n";

my %count;

for my $p (@{$smc_result->{structure}}) {
    $count{$p->{label}}++;
}

print "\n=== CONTEO ESTRUCTURA ===\n";

for my $k (sort keys %count) {
    print "$k => $count{$k}\n";
}

my $mw = MainWindow->new();

my $chart = Market::ChartEngine->new(
    mw         => $mw,
    market     => $market,
    indicators => $indicators,
);

$chart->run();