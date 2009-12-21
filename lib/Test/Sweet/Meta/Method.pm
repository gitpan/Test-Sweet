use MooseX::Declare;

role Test::Sweet::Meta::Method {
    use MooseX::Types::Moose qw(CodeRef ArrayRef Str);
    use Sub::Name;
    use Test::Builder;
    use Try::Tiny;
    use Test::Sweet::Exception::FailedMethod;
    use Test::Sweet::Meta::Test;

    has 'original_body' => (
        is       => 'ro',
        isa      => 'CodeRef',
        required => 1,
    );

    has 'requested_test_traits' => (
        is         => 'ro',
        isa        => ArrayRef[Str],
        predicate  => 'has_requested_test_traits',
        auto_deref => 1,
    );

    has 'test_traits' => (
        is         => 'ro',
        isa        => ArrayRef[Str],
        lazy_build => 1,
    );

    method _resolve_trait(Str $trait_name){
        my $real_test_trait = "Test::Sweet::Meta::Test::Trait::$trait_name";
        my $anon_test_trait = 'Test::Sweet::Meta::Test::Trait::__ANON__::' . $self->associated_metaclass->name. "::$trait_name";

        if($trait_name =~ /^[+](.+)$/){
            $trait_name = $1;
            Class::MOP::load_class($trait_name);
            return $trait_name;
        }
        elsif ( eval { Class::MOP::load_class($anon_test_trait); 1 } ) {
            return $anon_test_trait;
        }
        elsif ( eval { Class::MOP::load_class($real_test_trait); 1 } ) {
            return $real_test_trait;
        }
        else {
            confess "Cannot resolve test trait '$trait_name' to a class name.";
        }
    }

    method _build_test_traits {
        return [] unless $self->has_requested_test_traits;
        return [ map { $self->_resolve_trait($_) } $self->requested_test_traits ];
    }

    method has_actual_test_traits {
        return 1 if $self->has_requested_test_traits && @{$self->test_traits} > 0;
        return;
    }

    has 'test_metaclass' => (
        is         => 'ro',
        isa        => 'Class::MOP::Class',
        lazy_build => 1,
    );

    method _build_test_metaclass {
        # XXX: don't hard-code superclass, make it a role
        return Moose::Meta::Class->create_anon_class(
            superclasses => [ 'Test::Sweet::Meta::Test' ],
            cache        => 1,
            ($self->has_actual_test_traits ? (roles => $self->test_traits) : ()),

        );
    }

    requires 'wrap';
    requires 'body';

    around wrap($class: $code, %params) {
        my $self = $class->$orig($params{original_body}, %params);
        return $self;
    }

    around body {
        return (subname "<Test::Sweet test wrapper>", sub {
            my @args = @_;
            my $context = wantarray;
            my ($result, @result);

            my $b = Test::Builder->new; # TODO: let this be passed in
            $b->subtest(
                $self->name =>
                      subname "<Test::Sweet subtest>", sub {
                          try {
                              my $TEST = $self->test_metaclass->name->new( # BUILD
                                  test_body => sub { my @args = @_; return $self->$orig->(@args) },
                              );

                              # run actual test method
                              if($context){
                                  @result = $TEST->run(@args);
                              }
                              elsif(defined $context){
                                  $result = $TEST->run(@args);
                              }
                              else {
                                  $TEST->run(@args);
                              }
                              undef $TEST; # DEMOLISH
                              $b->done_testing;
                          }
                          catch {
                              die Test::Sweet::Exception::FailedMethod->new(
                                  class  => $self->package_name,
                                  method => $self->name,
                                  error  => $_,
                              );
                          };
                      },
            );
            return @result if $context;
            return $result if defined $context;
            return;
        });
    }
}

__END__

=head1 NAME

Test::Sweet::Meta::Method - metamethod trait for running method as tests
