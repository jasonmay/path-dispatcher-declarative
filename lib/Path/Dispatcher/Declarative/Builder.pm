package Path::Dispatcher::Declarative::Builder;
use Any::Moose;

our $OUTERMOST_DISPATCHER;
our $UNDER_RULE;

has dispatcher => (
    is          => 'ro',
    isa         => 'Path::Dispatcher',
    lazy        => 1,
    default     => sub { return Path::Dispatcher->new },
);

has case_sensitive_tokens => (
    is          => 'rw',
    isa         => 'Bool',
    default     => 1,
);

has token_delimiter => (
    is          => 'rw',
    isa         => 'Str',
    default     => ' ',
);

__PACKAGE__->add_sugar_method(next_rule => sub {
    die "Path::Dispatcher next rule\n";
});

__PACKAGE__->add_sugar_method(last_rule => sub {
    die "Path::Dispatcher abort\n";
});

__PACKAGE__->add_optional_sugar_method(dispatch => sub {
    my $self = shift;

    local $OUTERMOST_DISPATCHER = $self->dispatcher
        if !$OUTERMOST_DISPATCHER;

    $OUTERMOST_DISPATCHER->dispatch(@_);
});

__PACKAGE__->add_optional_sugar_method(run => sub {
    my $self = shift;

    local $OUTERMOST_DISPATCHER = $self->dispatcher
        if !$OUTERMOST_DISPATCHER;

    $OUTERMOST_DISPATCHER->run(@_);
});

__PACKAGE__->add_sugar_method(complete => sub {
    my $self       = shift;
    my $dispatcher = shift;

    local $OUTERMOST_DISPATCHER = $self->dispatcher
        if !$OUTERMOST_DISPATCHER;

    $OUTERMOST_DISPATCHER->complete(@_);
});

__PACKAGE__->add_sugar_method(rewrite => sub {
    my $self = shift;
    my ($from, $to) = @_;
    my $rewrite = sub {
        local $OUTERMOST_DISPATCHER = $self->dispatcher
            if !$OUTERMOST_DISPATCHER;
        my $path = ref($to) eq 'CODE' ? $to->() : $to;
        $OUTERMOST_DISPATCHER->run($path, @_);
    };
    $self->_add_rule($from, $rewrite);
});

__PACKAGE__->add_sugar_method(on => sub {
    my $self = shift;
    $self->_add_rule(@_);
});

__PACKAGE__->add_sugar_method(enum => sub {
    my $self = shift;
    Path::Dispatcher::Rule::Enum->new(
        enum => [@_],
    );
});

__PACKAGE__->_add_sugar_method(then => sub {
    my $self = shift;
    my $block = shift;
    my $rule = Path::Dispatcher::Rule::Always->new(
        block => sub {
            $block->(@_);
            __PACKAGE__->next_rule;
        },
    );
    $self->_add_rule($rule);
}, takes_coderef => 1);

__PACKAGE__->_add_sugar_method(chain => sub {
    my $self = shift;
    my $block = shift;
    my $rule = Path::Dispatcher::Rule::Chain->new(
        block => $block,
    );
    $self->_add_rule($rule);
}, takes_coderef => 1);

__PACKAGE__->add_sugar_method(under => sub {
    my $self = shift;
    my ($matcher, $rules) = @_;

    my $predicate = $self->_create_rule($matcher, prefix => 1);

    my $under = Path::Dispatcher::Rule::Under->new(
        predicate => $predicate,
    );

    $self->_add_rule($under, @_);

    do {
        local $UNDER_RULE = $under;
        $rules->($UNDER_RULE);
    };
});

__PACKAGE__->add_sugar_method(redispatch_to => sub {
    my $self = shift;
    my $dispatcher = shift;

    # assume it's a declarative dispatcher
    if (!ref($dispatcher)) {
        $dispatcher = $dispatcher->dispatcher;
    }

    my $redispatch = Path::Dispatcher::Rule::Dispatch->new(
        dispatcher => $dispatcher,
    );

    $self->_add_rule($redispatch);
});

sub rule_creators {
    return {
        ARRAY => sub {
            my ($self, $tokens, %args) = @_;

            Path::Dispatcher::Rule::Tokens->new(
                tokens => $tokens,
                delimiter => $self->token_delimiter,
                case_sensitive => $self->case_sensitive_tokens,
                %args,
            ),
        },
        HASH => sub {
            my ($self, $metadata_matchers, %args) = @_;

            if (keys %$metadata_matchers == 1) {
                my ($field) = keys %$metadata_matchers;
                my ($value) = values %$metadata_matchers;
                my $matcher = $self->_create_rule($value);

                return Path::Dispatcher::Rule::Metadata->new(
                    field   => $field,
                    matcher => $matcher,
                    %args,
                );
            }

            die "Doesn't support multiple metadata rules yet";
        },
        CODE => sub {
            my ($self, $matcher, %args) = @_;
            Path::Dispatcher::Rule::CodeRef->new(
                matcher => $matcher,
                %args,
            ),
        },
        Regexp => sub {
            my ($self, $regex, %args) = @_;
            Path::Dispatcher::Rule::Regex->new(
                regex => $regex,
                %args,
            ),
        },
        empty => sub {
            my ($self, $undef, %args) = @_;
            Path::Dispatcher::Rule::Empty->new(
                %args,
            ),
        },
    };
}

sub _create_rule {
    my ($self, $matcher, %args) = @_;

    my $rule_creator;

    if ($matcher eq '') {
        $rule_creator = $self->rule_creators->{empty};
    }
    elsif (!ref($matcher)) {
        $rule_creator = $self->rule_creators->{ARRAY};
        $matcher = [$matcher];
    }
    else {
        $rule_creator = $self->rule_creators->{ ref $matcher };
    }

    $rule_creator or die "I don't know how to create a rule for type $matcher";

    return $rule_creator->($self, $matcher, %args);
}

sub _add_rule {
    my $self = shift;
    my $rule;

    if (blessed($_[0]) && $_[0]->isa('Path::Dispatcher::Rule')) {
        $rule = shift;
    }
    else {
        my ($matcher, $block) = splice @_, 0, 2;

        # set $1, etc
        my $old_block = $block;
        $block = sub {
            my $match = shift;
            my @pos = @{ $match->positional_captures };

            # we don't have direct write access to $1 and friends, so we have to
            # do this little hack. the only way we can update $1 is by matching
            # against a regex (5.10 fixes that)..
            my $re  = join '', map { defined($_) ? "(\Q$_\E)" : "(wontmatch)?" } @pos;
            my $str = join '', map { defined($_) ? $_         : ""             } @pos;

            # we need to check length because Perl's annoying gotcha of the empty regex
            # actually being an alias for whatever the previously used regex was
            # (useful last decade when qr// hadn't been invented)
            # we need to do the match anyway, because we have to clear the number vars
            ($str, $re) = ("x", "x") if length($str) == 0;

            $str =~ qr{^$re$}
                or die "Unable to match '$str' against a copy of itself ($re)!";


            $old_block->(@_);
        };

        $rule = $self->_create_rule($matcher, block => $block);
    }

    # FIXME: broken since move from ::Declarative
    # XXX: caller level should be closer to $Test::Builder::Level
#    my (undef, $file, $line) = caller(1);
    my (undef, $file, $line) = caller(2);
    my $rule_name = "$file:$line";

    if (!defined(wantarray)) {
        my $parent = $UNDER_RULE || $self->dispatcher;
        $parent->add_rule($rule);
    }
    else {
        return $rule, @_;
    }
}

sub _add_sugar_method {
    my $class = shift;
    my ($name, $body, %method_args) = @_;

    my $exportable_method_metaclass = $class->meta->create_anon_class(
        superclasses => [$class->meta->method_metaclass],
        roles        => ['Path::Dispatcher::Declarative::Exportable'],
    );

    my $method = $exportable_method_metaclass->name->wrap(
        $body,
        name                  => $name,
        package_name          => $class,
        %method_args,
    );

    $class->meta->add_method($name => $method);
}

sub add_sugar_method {
    my $class = shift;
    $class->_add_sugar_method(@_);
}

sub add_optional_sugar_method {
    my $class = shift;
    $class->_add_sugar_method(@_, invocable_from_caller => 1);
}


__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

