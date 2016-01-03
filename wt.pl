use strict;
use utf8;
use open qw(:std :utf8);
use Parse::JCONF;
use Getopt::Long;
use Encode::Locale;
use Encode qw (encode decode);
use warnings;
use DDP;
use feature 'say';



GetOptions (
            "schedule=s"  => \my $schedule_arg,
            "config=s"  => \my $config_arg
            )
or die "Error in command line arguments\n";

if (!$schedule_arg && !$config_arg) { die "USAGE: $0 -schedule WORKING_TIME_STRING -config FILE.conf" }


my $config = Parse::JCONF->new(autodie => 1)->parse_file($config_arg)
    or die "ERROR! Can't open configuration file: $!";


# Поддерживаем русский язык из консоли
$schedule_arg = decode (locale => $schedule_arg);


# Формируем ругулярные выражения для всех значимых участков текста, дней недели, перерывов и интервалов
my $make_sense = '(?:';
my $days_regexp = '^(?:';
my $time_regexp ='^';
my $breaks_regexp ='^';
my $interval_regexp ='^';

foreach ( @{$config->{ru}} ) {
    $make_sense .= $_->{regexp} . '|';
    if ( $_->{type} eq 'day' ) { $days_regexp .= $_->{regexp} . '|' }
    if ( $_->{type} eq 'time' ) { $time_regexp .= $_->{regexp} . '|' }
    if ( $_->{type} eq 'break' ) { $breaks_regexp .= $_->{regexp} . '|' }
    if ( $_->{type} eq 'interval' ) { $interval_regexp .= $_->{regexp} . '|' }
}
$make_sense =~ s!\|$!)!;
$days_regexp =~ s!\|$!)\$!;
$time_regexp =~ s!\|$!\$!;
$breaks_regexp =~ s!\|$!\$!;
$interval_regexp =~ s!\|$!\$!;



sub _parse_schedule {
    my $schedule = shift;
    my @e = $schedule =~ m!$make_sense!gi;
    
    my ($i, $time_obj_cnt) = 0;
    my %extracted_days;
    my $index;
    my @s;
    
    while ($i <= $#e) {
        # Если день недели - помещаем в соответствующий элемент массива расписания ЗАГОТОВКУ
        if ( $e[$i] =~ m!$days_regexp!i ) {
            my $day = $e[$i];
            foreach ( @{$config->{ru}} ) {
                if ($day =~ m!$_->{regexp}!i) {
                    # Индекс начального дня диапазона
                    $index = $_->{index};
                    # Валидация - День недели фигурирует в расписании более одного раза (в т.ч. в интервале)
                    if ( exists $extracted_days{$index} ) { die "ERROR! Validation is not passed (day-object appears more than once)\n" }
                    $extracted_days{$index} = 1;
                }
            }
            
            # ЗАГОТОВКА
            $s[$index] = { from => 'NA', to => 'NA' };
            $i++;
        }
        
        # Если знаки интервала,
        elsif ( $e[$i] =~ m!$interval_regexp!i ) {
            
            unless ( $e[$i+1] =~ m!(?:$days_regexp|$time_regexp)!i and $e[$i-1] =~ m!(?:$days_regexp|$time_regexp)!i ) {
                die "ERROR! Validation is not passed (incorrect placement of interval-object)\n"
            }
            
            # а следом день недели - помещаем в каждый элемент интервала ЗАГОТОВКУ
            if ( $e[$i+1] =~ m!$days_regexp!i ) {
                foreach ( @{$config->{ru}} ) {
                    if ( $_->{type} eq 'day' && $_->{index} > $index ) {
                        # Валидация - День недели фигурирует в расписании более одного раза (в т.ч. в интервале)
                        if ( exists $extracted_days{ $_->{index} } ) { die "ERROR! Validation is not passed (day-object appears more than once)\n" }
                        $extracted_days{ $_->{index} } = 1;
                        
                        # ЗАГОТОВКА
                        $s[ $_->{index} ] = { from => 'NA', to => 'NA' };
                        if ( $e[$i+1] =~ m!$_->{regexp}!i ) {
                            undef $index;
                            last;
                        }
                    }
                }
                # Валидация - Интервал дней ПОЗДНИЙ-РАННИЙ. Когда индексы дней недели закончились, а правая граница интервала так и не встретилась.
                if (defined $index) { die "ERROR! Validation is not passed (interval-object between later and earlier or the same days)\n" }
                
                $i+=2;
            }
            
            # Иначе - переходим к следующему элементу
            else { $i++ }
        }
        
        # Если перерыв - обходим массив расписания и добавляем ЗАГОТОВКУ перерыва во все элементы, где его нет
        elsif ( $e[$i] =~ m!$breaks_regexp!i ) {
            foreach (@s) {
                if ( defined ($_) && not defined ($_->{break}) ) {
                    # ЗАГОТОВКА
                    $_->{break} = { from => 'NA', to => 'NA' };
                }
            }
            $i++;
        }
        
        # Если часы работы - помещаем время в первую незанятую ЗАГОТОВКУ
        elsif ( $e[$i] =~ m!$time_regexp!i ) {
            # Валидация - более двух цифр подряд
            if ( (defined $e[$i+2]) &&
                 ($e[$i+1] =~ m!$time_regexp!i and $e[$i+2] =~ m!$time_regexp!i) ) { die "ERROR! Validation is not passed (more than two consecutive hours-objects)\n" }
            
            foreach (@s) {
                if (defined ($_->{from}) and $_->{from} eq 'NA') { $_->{from} = _normalize_schedule_time($e[$i]); next }
                if (defined ($_->{to}) and $_->{to} eq 'NA') {
                    $_->{to} = _normalize_schedule_time($e[$i]);
                    # Валидация - Время окончания работы меньше времени начала
                    my ($x, $y) = map { my $z = $_; $z =~ s!:!!g; $z } ( $_->{from}, $_->{to} );
                    if (    ($y && $x) and
                            ($x < 200000) and
                            ($y <= $x)
                            ) { die "ERROR! Validation is not passed (TO hours-object is less than FROM hours-object in working time)\n" }
                    
                    next;
                }
                
                if (defined ($_->{break}) and $_->{break}->{from} eq 'NA') { $_->{break}->{from} = _normalize_schedule_time($e[$i]); next }
                if (defined ($_->{break}) and $_->{break}->{to} eq 'NA') {
                    $_->{break}->{to} = _normalize_schedule_time($e[$i]);
                    # Валидация - Время окончания перерыва меньше времени начала
                    my ($x, $y) = map { my $z = $_; $z =~ s!:!!g; $z } ( $_->{break}->{from}, $_->{break}->{to} );
                    if (    ($y && $x) and
                            ($x < 200000) and
                            ($y <= $x)
                            ) { die "ERROR! Validation is not passed (TO hours-object is less than FROM hours-object in break)\n" }
                    
                    # Валидация - Перерыв выходит за рамки времени работы
                    my ($xx, $yy) = map { my $z = $_; $z =~ s!:!!g; $z } ( $_->{from}, $_->{to} );
                    my $steps;
                    until ( ($xx < $x) && ($x < $y) && ($y < $yy) ) {
                        for ($xx, $x, $y, $yy) { $_ =~ s!^24(.*)!00$1! if $_ >= 240000; $_+=10000 }
                        $steps++;
                        if ($steps > 24) { die "ERROR! Validation is not passed (break interval is out of working time)\n" }
                    }
                }
            }
            $i++;
            $time_obj_cnt++;
        }
    }
    
    # Валидация - отсутствуют часы работы
    unless (defined $time_obj_cnt) { die "ERROR! Validation is not passed (no one hours-object was found)\n" }
    # Валидация - количество цифр не кратно двум
    if ($time_obj_cnt % 2) { die "ERROR! Validation is not passed (the count of hours-objects is not a multiple of two)\n" }
    # Валидация - отсутствуют дни работы
    unless (%extracted_days) { $schedule =~ s!^!пн-вс !; return _parse_schedule($schedule) }
    
    return \@s;
}



sub _normalize_schedule_time {
    my $t = shift;
    if ($t =~ m!^\d{2}([:._]\d{2}){1,2}$!) {
        $t =~ s![:._]!:!g;
        if ($t =~ m!^\d{2}:\d{2}:\d{2}$!) { $t =~ s!:\d{2}$!! }
        
        # Пост-валидация - заменяем 59 минут
        if ($t =~ m!:59$!) {
            $t = join(':', map { $_+=1 } split (/:/, $t));
            $t =~ s!^24!00!;
            $t =~ s!60$!00!;
        }
        
        return $t.':00';
    }
    
    elsif ($t =~ m!^\d$! and $t != 0) { return '0'.$t.':00:00' }
    elsif ($t =~ m!^\d{2}$!) { return $t.':00:00' }
}



my $p = _parse_schedule($schedule_arg);
p  $p;
