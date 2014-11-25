package Bot::Backbone::Service::Web::ICal;
use v5.10;
use Bot::Backbone::Service;

use Data::ICal;
use Data::ICal::DateTime 0.81;
use DateTime::Format::Human::Duration;
use List::Util qw( max );
use String::Errf qw( errf );

with qw(
    Bot::Backbone::Service::Role::Service
    Bot::Backbone::Service::Role::ChatConsumer
    Bot::Backbone::Service::Role::Storage
);

has ua => (
    is          => 'ro',
    isa         => 'LWP::UserAgent',
    required    => 1,
    lazy        => 1,
    builder     => '_build_ua',
    handles     => [ 'get' ],
);

sub _build_ua { LWP::UserAgent->new }

has url => (
    is          => 'ro',
    isa         => 'Str',
    predicate   => 'has_url',
);

has calendar_refresh_after => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    lazy        => 1,
    builder     => '_build_calendar_refresh_after',
);

sub _build_calendar_refresh_after {
    my $self = shift;

    if ($self->has_url) {
        return 86400; # update once a day
    }
    else {
        return -1; # update never
    }
}

has calendar_stale_after => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    lazy        => 1,
    builder     => '_build_calendar_stale_after',
);

sub _build_calendar_stale_after {
    my $self = shift;

    if ($self->has_url) {
        return 259200; # after 3 days
    }
    else {
        return -1; # update never
    }
}

has calendar_refresh_interval => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    default     => 86400,
);

has calendar_announcement_interval => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    default     => 60,
);

has max_calendar_announcement_lookback_period => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    default     => 1800,
);

has calendar_announcement_lookahead_period => (
    is          => 'ro',
    isa         => 'Int',
    required    => 1,
    default     => 1800,
);

has calendar => (
    is          => 'rw',
    predicate   => 'has_calendar',
);

has calendar_timestamp => (
    is          => 'rw',
    isa         => 'Int',
    predicate   => 'has_calendar_timestamp',
);

has calendar_refresh_timer => (
    is          => 'rw',
);

has calendar_announcement_timer => (
    is          => 'rw',
);

has time_zone => (
    is          => 'rw',
    isa         => 'Str',
    required    => 1,
    lazy        => 1,
    builder     => '_build_time_zone',
);

sub _build_time_zone { 'UTC' }

has message_format => (
    is          => 'rw',
    isa         => 'Str',
    required    => 1,
    default     => '%{summary}s',
);

sub BUILD {
    my $self = shift;
    die "No calendar or url is set.\n" unless $self->has_calendar or $self->has_url;
}

sub initialize {
    my $self = shift;

    #say "Running initialize...";

    if ($self->has_url and $self->calendar_refresh_after >= 0) {
        my $rt = AnyEvent->timer(
            interval => $self->calendar_refresh_interval,
            cb       => sub { $self->refresh_calendar },
        );

        $self->calendar_refresh_timer($rt);
    }

    my $at = AnyEvent->timer(
        after    => $self->calendar_announcement_interval,
        interval => $self->calendar_announcement_interval,
        cb       => sub { $self->announce_event },
    );

    $self->calendar_announcement_timer($at);
}

sub load_schema {
    my ($self, $conn) = @_;

    $conn->run(fixup => sub {
        $_->do(q[
            CREATE TABLE IF NOT EXISTS last_announced(
                last_announcement INT,
                PRIMARY KEY (last_announcement)
            )
        ]);
    });
}

sub refresh_calendar {
    my $self = shift;

    #say "Running refresh_calendar...";

    return unless $self->has_url;
    return if $self->has_calendar and $self->calendar_refresh_after < 0;

    my $timestamp = time;
    my $delta     = $timestamp - ($self->calendar_timestamp // $timestamp);

    #say "Calendar delta: $delta";

    return if $delta < $self->calendar_refresh_after and $self->has_calendar_timestamp;

    #say "Calendar needs refresh...";

    my $res = $self->get( $self->url );

    if (!$res->is_success) {
        $self->send_message({ text => 'I cannot seem to fetch the calendar.' })
            if $self->calendar_stale_after >= 0 && $delta > $self->calendar_stale_after;

        warn "FAILED TO FETCH CALENDAR:\n\n".$res->as_string."\n\n";
        return;
    }

    my $calendar = Data::ICal->new( data => $res->content );
    $self->calendar($calendar);
    $self->calendar_timestamp($timestamp);

    #say "Calendar refreshed.";

    return 1;
}

sub announce_event {
    my $self = shift;

    #say "Running announce_event...";

    return unless $self->has_calendar;

    my $now = time;

    my ($last_announcement) = $self->db_conn->run(fixup => sub {
        $_->selectrow_array(q[
            SELECT last_announcement
              FROM last_announced
             LIMIT 1
        ]);
    }) // $now - $self->max_calendar_announcement_lookback_period;

    my $lookback = max($last_announcement, $now - $self->max_calendar_announcement_lookback_period);
    my $lookahead = $now + $self->calendar_announcement_lookahead_period;

    my $lookback_dt = DateTime->from_epoch( epoch => $lookback, time_zone => $self->time_zone );
    my $lookahead_dt = DateTime->from_epoch( epoch => $lookahead, time_zone => $self->time_zone );

    #say "lookback  = ", $lookback_dt, " ", $lookback_dt->time_zone_long_name;
    #say "lookahead = ", $lookahead_dt, " ", $lookahead_dt->time_zone_long_name;

    my $lookup = DateTime::Span->from_datetimes(
        start => DateTime->from_epoch( epoch => $lookback,  time_zone => $self->time_zone ),
        end   => DateTime->from_epoch( epoch => $lookahead, time_zone => $self->time_zone ),
    );

    my $announced = 0;
    for my $event ($self->calendar->events) {

        my @recurrences;
        if ($event->recurrence) {
            @recurrences = ($event->start, $event->recurrence->as_list( span => $lookup ));
        }
        else {
            # # TIME ZONE HANDLING IN Data::ICal::DateTime is stupid!
            # my $start = $event->start;
            # my $dtstart = $event->property('dtstart');
            # if ($dtstart && @$dtstart && $dtstart->[0]->parameters->{TZID}) {
            #     $start->set_time_zone($dtstart->[0]->parameters->{TZID});
            # }

            @recurrences = ($event->start);
        }

        #say "recurrences: ", join ", ", map { "$_" } (@recurrences);
        #say "time zones:  ", join ", ", map { $_->time_zone->name } (@recurrences);
        my $found = 0;
        RECURRENCE: for my $recurrence (@recurrences) {
            $recurrence->set_time_zone('UTC');
            #warn "checking $recurrence ", $recurrence->time_zone->name, "\n";
            if ($lookup->contains($recurrence)) {
                #warn "found\n";
                $found++;
                last RECURRENCE;
            }
        }

        next unless $found;

        my $text = errf($self->message_format, {
            time_until  => $self->format_time_until($event->start, DateTime->from_epoch( epoch => $now )),
            start       => $event->start,
            end         => $event->end,
            uid         => $event->uid,
            summary     => $event->summary,
            description => $event->description,
        });

        #say "announcing $text";

        $self->send_message({ text => $text });
        $announced++;
    }

    if ($announced) {
        $self->db_conn->run(fixup => sub {
            $_->do(q[ DELETE FROM last_announced ]);
            $_->do(q[
                INSERT INTO last_announced VALUES (?)
            ], undef, $lookahead);
        });
    }

    return 1;
}

sub format_time_until {
    my ($self, $event_time, $now) = @_;

    my $fmt = DateTime::Format::Human::Duration->new;
    return $fmt->format_duration_between(
        $now,
        $event_time,
        significant_units => 1,
        past              => '%s ago',
        future            => 'in %s',
        no_time           => 'right now',
    );
}

sub receive_message { }

__PACKAGE__->meta->make_immutable;
