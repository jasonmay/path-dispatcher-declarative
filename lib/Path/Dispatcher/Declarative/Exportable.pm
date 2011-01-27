package Path::Dispatcher::Declarative::Exportable;
use Moose::Role;

has invocable_from_caller => (
    is  => 'ro',
    isa => 'Bool',
);

# exports as sub (&)
has takes_coderef => (
    is  => 'ro',
    isa => 'Bool',
);

no Moose::Role;

1;
