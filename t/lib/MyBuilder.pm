package MyBuilder;
use Any::Moose;
extends 'Path::Dispatcher::Declarative::Builder';

__PACKAGE__->add_sugar_method(
    command => sub {
        my $self = shift;
        my $path = shift;
        $path = "command_$path" if $path and not ref $path;
        $self->on($path, @_);
    }
);

1;
