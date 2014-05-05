package Bot::Backbone::Service::Web::LinkTitle;
use v5.10;
use Bot::Backbone::Service;

with qw(
    Bot::Backbone::Service::Role::Service
    Bot::Backbone::Service::Role::Responder
);

use URI::Find;
use URI::Title qw( title );

service_dispatcher as {
    also not_command respond_by_method 'describe_links';
};

has exclude_urls => (
    is          => 'rw',
    isa         => 'ArrayRef[RegexpRef]',
    required    => 1,
    default     => sub { [] },
    traits      => [ 'Array' ],
    handles     => {
        list_exclude_urls => 'elements',
    },
);

sub excluded_url {
    my ($self, $url) = @_;

    for my $exclusion ($self->list_exclude_urls) {
        return 1 if $url =~ /$exclusion/;
    }

    return '';
}

sub find_links {
    my ($self, $text) = @_;

    my @links;
    my $finder = URI::Find->new(sub {
        my $uri = shift;

        return if $self->excluded_url($uri);

        push @links, $uri;
    });
    $finder->find(\$text);

    return @links;
}

sub describe_links {
    my ($self, $message) = @_;

    my @messages;
    my @links = $self->find_links($message->text);
    for my $link (@links) {
        push @messages, title({ url => $link });
    }

    return @messages;
}

sub initialize { }

__PACKAGE__->meta->make_immutable;
