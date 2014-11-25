package Bot::Backbone::Service::Web::LinkTitle;
use v5.10;
use Bot::Backbone::Service;

# ABSTRACT: Retrieve the titles of links pasted into chat

with qw(
    Bot::Backbone::Service::Role::Service
    Bot::Backbone::Service::Role::Responder
);

use URI::Find;
use URI::Title qw( title );

=head1 SYNOPSIS

    service link_titles => (
        service => 'Web::LinkTitle'
    );

    # in chat
    alice> https://metacpan.org/release/Acme-Fork-Bomb
    bot> Acme-Fork-Bomb-2.0 - crashes your program and probably your system - metacpan.org

=head1 DESCRIPTION

Whenever someone pasts a link to a chat the bot is monitoring, the bot will use
L<URI::Title> to find the title or description of the linked document and report
it back to the chat.

=head1 DISPATCHER

This monitors all chats and looks for links in them. It locates URLs in the
messages using L<URI::Find>. When a link is found, it is checked using
L<URI::Title> and whatever that module finds is reported to the chat.

=cut

service_dispatcher as {
    also not_command respond_by_method 'describe_links';
};

=head1 ATTRIBUTES

=head2 exclude_urls

This is a list of regular expressions used to identify URLs you want to exclude
from being checked. For example, you might frequently link to an internal site
that requires a login that the bot does not have access to. You can keep it from
trying to report the link titles of those, which would otherwise just be noise
like "Please login".

=cut

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

=head1 METHODS

=head2 excluded_url

Checks to see if a URL matches any of the regexes in L</exclude_urls>.

=cut

sub excluded_url {
    my ($self, $url) = @_;

    for my $exclusion ($self->list_exclude_urls) {
        return 1 if $url =~ /$exclusion/;
    }

    return '';
}

=head2 find_links

Helper that finds URLs in text using L<URI::Find>.

=cut

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

=head2 describe_links

Looks at every chat message and searches it for URLs to fetch the
title/description and reports the title/description back to the chat.

=cut

sub describe_links {
    my ($self, $message) = @_;

    my @messages;
    my @links = $self->find_links($message->text);
    for my $link (@links) {
        push @messages, title({ url => $link });
    }

    return @messages;
}

=head2 initialize

No op.

=cut

sub initialize { }

__PACKAGE__->meta->make_immutable;
