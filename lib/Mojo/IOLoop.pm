package Mojo::IOLoop;
use Mojo::Base 'Mojo::EventEmitter';

# "Professor: Amy, technology isn't intrinsically good or evil. It's how it's
#             used. Like the death ray."
use Carp 'croak';
use Mojo::IOLoop::Client;
use Mojo::IOLoop::Delay;
use Mojo::IOLoop::Server;
use Mojo::IOLoop::Stream;
use Mojo::IOLoop::Subprocess;
use Mojo::Reactor::Poll;
use Mojo::Util qw(md5_sum steady_time);
use Scalar::Util qw(blessed weaken);

use constant DEBUG => $ENV{MOJO_IOLOOP_DEBUG} || 0;

has max_accepts     => 0;
has max_connections => 1000;
has reactor         => sub {
  my $class = Mojo::Reactor::Poll->detect;
  warn "-- Reactor initialized ($class)\n" if DEBUG;
  return $class->new->catch(sub { warn "@{[blessed $_[0]]}: $_[1]" });
};

# Ignore PIPE signal
$SIG{PIPE} = 'IGNORE';

# Initialize singleton reactor early
__PACKAGE__->singleton->reactor;

sub acceptor {
  my ($self, $acceptor) = (_instance(shift), @_);

  # Find acceptor for id
  return $self->{acceptors}{$acceptor} unless ref $acceptor;

  # Connect acceptor with reactor
  $self->{acceptors}{my $id = $self->_id} = $acceptor;
  weaken $acceptor->reactor($self->reactor)->{reactor};

  # Allow new acceptor to get picked up
  $self->_not_accepting->_maybe_accepting;

  return $id;
}

sub client {
  my ($self, $cb) = (_instance(shift), pop);
  my $args = ref $_[0] ? $_[0] : {@_};

  my $id = $self->_id;
  my $client = $self->{out}{$id}{client} = Mojo::IOLoop::Client->new;
  weaken $client->reactor($self->reactor)->{reactor};
  my $class = delete $args->{stream_class} || 'Mojo::IOLoop::Stream';

  weaken $self;
  $client->on(
    connect => sub {
      delete $self->{out}{$id}{client};
      my $stream = $class->new(pop);
      $self->_stream($stream => $id);
      $self->$cb(undef, $stream);
    }
  );
  $client->on(error => sub { $self->_remove($id); $self->$cb(pop, undef) });
  $client->connect($args);

  return $id;
}

sub delay {
  my $delay = Mojo::IOLoop::Delay->new;
  weaken $delay->ioloop(_instance(shift))->{ioloop};
  return @_ ? $delay->steps(@_) : $delay;
}

sub is_running { _instance(shift)->reactor->is_running }

sub next_tick {
  my ($self, $cb) = (_instance(shift), @_);
  weaken $self;
  return $self->reactor->next_tick(sub { $self->$cb });
}

sub one_tick {
  my $self = _instance(shift);
  croak 'Mojo::IOLoop already running' if $self->is_running;
  $self->reactor->one_tick;
}

sub recurring { shift->_timer(recurring => @_) }

sub remove {
  my ($self, $id) = (_instance(shift), @_);
  my $c = $self->{in}{$id} || $self->{out}{$id};
  if ($c && (my $stream = $c->{stream})) { return $stream->close_gracefully }
  $self->_remove($id);
}

sub reset {
  my $self = _instance(shift);
  delete @$self{qw(accepting acceptors events in out stop)};
  $self->reactor->reset;
  $self->stop;
}

sub server {
  my ($self, $cb) = (_instance(shift), pop);
  my $args = ref $_[0] ? $_[0] : {@_};

  my $server = Mojo::IOLoop::Server->new;
  my $class = delete $args->{stream_class} || 'Mojo::IOLoop::Stream';
  weaken $self;
  $server->on(
    accept => sub {
      my $stream = $class->new(pop);
      $self->$cb($stream, $self->_stream($stream, $self->_id, 1));

      # Enforce connection limit (randomize to improve load balancing)
      if (my $max = $self->max_accepts) {
        $self->{accepts} //= $max - int rand $max / 2;
        $self->stop_gracefully if ($self->{accepts} -= 1) <= 0;
      }

      # Stop accepting if connection limit has been reached
      $self->_not_accepting if $self->_limit;
    }
  );
  $server->listen($args);

  return $self->acceptor($server);
}

sub singleton { state $loop = shift->SUPER::new }

sub start {
  my $self = _instance(shift);
  croak 'Mojo::IOLoop already running' if $self->is_running;
  $self->reactor->start;
}

sub stop { _instance(shift)->reactor->stop }

sub stop_gracefully {
  my $self = _instance(shift)->_not_accepting;
  ++$self->{stop} and !$self->emit('finish')->_in and $self->stop;
}

sub stream {
  my ($self, $stream) = (_instance(shift), @_);
  return $self->_stream($stream => $self->_id) if ref $stream;
  my $c = $self->{in}{$stream} || $self->{out}{$stream} || {};
  return $c->{stream};
}

sub subprocess {
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  weaken $subprocess->ioloop(_instance(shift))->{ioloop};
  return @_ ? $subprocess->run(@_) : $subprocess;
}

sub timer { shift->_timer(timer => @_) }

sub transition {
  my ($self, $id, $class) = (_instance(shift), @_);

  my $old = $self->stream($id);
  my $new = $class->new($old->steal_handle);
  $self->_stream($new, $id, !!$self->{in}{$id});
  $old->transition($new);

  return $new;
}

sub _id {
  my $self = shift;
  my $id;
  do { $id = md5_sum 'c' . steady_time . rand }
    while $self->{in}{$id} || $self->{out}{$id} || $self->{acceptors}{$id};
  return $id;
}

sub _in { scalar keys %{shift->{in} || {}} }

sub _instance { ref $_[0] ? $_[0] : $_[0]->singleton }

sub _limit { $_[0]{stop} ? 1 : $_[0]->_in >= $_[0]->max_connections }

sub _maybe_accepting {
  my $self = shift;
  return if $self->{accepting} || $self->_limit;
  $_->start for values %{$self->{acceptors} || {}};
  $self->{accepting} = 1;
}

sub _not_accepting {
  my $self = shift;
  return $self unless delete $self->{accepting};
  $_->stop for values %{$self->{acceptors} || {}};
  return $self;
}

sub _out { scalar keys %{shift->{out} || {}} }

sub _remove {
  my ($self, $id) = @_;

  # Timer
  return unless my $reactor = $self->reactor;
  return if $reactor->remove($id);

  # Acceptor
  return $self->_not_accepting->_maybe_accepting
    if delete $self->{acceptors}{$id};

  # Connection
  return unless delete $self->{in}{$id} || delete $self->{out}{$id};
  return $self->stop if $self->{stop} && !$self->_in;
  $self->_maybe_accepting;
  warn "-- $id <<< $$ (@{[$self->_in]}:@{[$self->_out]})\n" if DEBUG;
}

sub _stream {
  my ($self, $stream, $id, $server) = @_;

  # Connect stream with reactor
  $self->{$server ? 'in' : 'out'}{$id}{stream} = $stream;
  warn "-- $id >>> $$ (@{[$self->_in]}:@{[$self->_out]})\n" if DEBUG;
  weaken $stream->reactor($self->reactor)->{reactor};
  weaken $self;
  $stream->on(close => sub { $self && $self->_remove($id) });
  $stream->start;

  return $id;
}

sub _timer {
  my ($self, $method, $after, $cb) = (_instance(shift), @_);
  weaken $self;
  return $self->reactor->$method($after => sub { $self->$cb });
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop - Minimalistic event loop

=head1 SYNOPSIS

  use Mojo::IOLoop;

  # Listen on port 3000
  Mojo::IOLoop->server({port => 3000} => sub {
    my ($loop, $stream) = @_;

    $stream->on(read => sub {
      my ($stream, $bytes) = @_;

      # Process input chunk
      say $bytes;

      # Write response
      $stream->write('HTTP/1.1 200 OK');
    });
  });

  # Connect to port 3000
  my $id = Mojo::IOLoop->client({port => 3000} => sub {
    my ($loop, $err, $stream) = @_;

    $stream->on(read => sub {
      my ($stream, $bytes) = @_;

      # Process input
      say "Input: $bytes";
    });

    # Write request
    $stream->write("GET / HTTP/1.1\x0d\x0a\x0d\x0a");
  });

  # Add a timer
  Mojo::IOLoop->timer(5 => sub {
    my $loop = shift;
    $loop->remove($id);
  });

  # Start event loop if necessary
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

L<Mojo::IOLoop> is a very minimalistic event loop based on L<Mojo::Reactor>, it
has been reduced to the absolute minimal feature set required to build solid
and scalable non-blocking clients and servers.

Depending on operating system, the default per-process and system-wide file
descriptor limits are often very low and need to be tuned for better
scalability. The C<LIBEV_FLAGS> environment variable should also be used to
select the best possible L<EV> backend, which usually defaults to the not very
scalable C<select>.

  LIBEV_FLAGS=1   # select
  LIBEV_FLAGS=2   # poll
  LIBEV_FLAGS=4   # epoll (Linux)
  LIBEV_FLAGS=8   # kqueue (*BSD, OS X)

The event loop will be resilient to time jumps if a monotonic clock is
available through L<Time::HiRes>. A TLS certificate and key are also built
right in, to make writing test servers as easy as possible. Also note that for
convenience the C<PIPE> signal will be set to C<IGNORE> when L<Mojo::IOLoop> is
loaded.

For better scalability (epoll, kqueue) and to provide non-blocking name
resolution, SOCKS5 as well as TLS support, the optional modules L<EV> (4.0+),
L<Net::DNS::Native> (0.15+), L<IO::Socket::Socks> (0.64+) and
L<IO::Socket::SSL> (2.009+) will be used automatically if possible. Individual
features can also be disabled with the C<MOJO_NO_NNR>, C<MOJO_NO_SOCKS> and
C<MOJO_NO_TLS> environment variables.

See L<Mojolicious::Guides::Cookbook/"REAL-TIME WEB"> for more.

=head1 EVENTS

L<Mojo::IOLoop> inherits all events from L<Mojo::EventEmitter> and can emit the
following new ones.

=head2 finish

  $loop->on(finish => sub {
    my $loop = shift;
    ...
  });

Emitted when the event loop wants to shut down gracefully and is just waiting
for all existing connections to be closed.

=head1 ATTRIBUTES

L<Mojo::IOLoop> implements the following attributes.

=head2 max_accepts

  my $max = $loop->max_accepts;
  $loop   = $loop->max_accepts(1000);

The maximum number of connections this event loop is allowed to accept, before
shutting down gracefully without interrupting existing connections, defaults to
C<0>. Setting the value to C<0> will allow this event loop to accept new
connections indefinitely. Note that up to half of this value can be subtracted
randomly to improve load balancing between multiple server processes, and to
make sure that not all of them restart at the same time.

=head2 max_connections

  my $max = $loop->max_connections;
  $loop   = $loop->max_connections(100);

The maximum number of accepted connections this event loop is allowed to handle
concurrently, before stopping to accept new incoming connections, defaults to
C<1000>.

=head2 reactor

  my $reactor = $loop->reactor;
  $loop       = $loop->reactor(Mojo::Reactor->new);

Low-level event reactor, usually a L<Mojo::Reactor::Poll> or
L<Mojo::Reactor::EV> object with a default subscriber to the event
L<Mojo::Reactor/"error">.

  # Watch if handle becomes readable or writable
  Mojo::IOLoop->singleton->reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  });

  # Change to watching only if handle becomes writable
  Mojo::IOLoop->singleton->reactor->watch($handle, 0, 1);

  # Remove handle again
  Mojo::IOLoop->singleton->reactor->remove($handle);

=head1 METHODS

L<Mojo::IOLoop> inherits all methods from L<Mojo::EventEmitter> and implements
the following new ones.

=head2 acceptor

  my $server = Mojo::IOLoop->acceptor($id);
  my $server = $loop->acceptor($id);
  my $id     = $loop->acceptor(Mojo::IOLoop::Server->new);

Get L<Mojo::IOLoop::Server> object for id or turn object into an acceptor.

=head2 client

  my $id
    = Mojo::IOLoop->client(address => '127.0.0.1', port => 3000, sub {...});
  my $id = $loop->client(address => '127.0.0.1', port => 3000, sub {...});
  my $id = $loop->client({address => '127.0.0.1', port => 3000} => sub {...});

Open a TCP/IP or UNIX domain socket connection with L<Mojo::IOLoop::Client> and
create a stream object (usually L<Mojo::IOLoop::Stream>), takes the same
arguments as L<Mojo::IOLoop::Client/"connect"> in addition to C<stream_class>.

  # Connect to 127.0.0.1 on port 3000 with a custom stream class
  my $class = 'Mojo::IOLoop::Stream::HTTPClient';
  Mojo::IOLoop->client({port => 3000, stream_class => $class} => sub {
    my ($loop, $err, $stream) = @_;
    ...
  });

=head2 delay

  my $delay = Mojo::IOLoop->delay;
  my $delay = $loop->delay;
  my $delay = $loop->delay(sub {...});
  my $delay = $loop->delay(sub {...}, sub {...});

Build L<Mojo::IOLoop::Delay> object to use as a promise and/or for flow-control.
Callbacks will be passed along to L<Mojo::IOLoop::Delay/"steps">.

  # Wrap continuation-passing style APIs with promises
  my $ua = Mojo::UserAgent->new;
  sub get {
    my $promise = Mojo::IOLoop->delay;
    $ua->get(@_ => sub {
      my ($ua, $tx) = @_;
      my $err = $tx->error;
      $promise->resolve($tx) if !$err || $err->{code};
      $promise->reject($err->{message});
    });
    return $promise;
  }
  my $mojo = get('https://mojolicious.org');
  my $cpan = get('https://metacpan.org');
  Mojo::Promise->race($mojo, $cpan)->then(sub { say shift->req->url })->wait;

  # Synchronize multiple non-blocking operations
  my $delay = Mojo::IOLoop->delay(sub { say 'BOOM!' });
  for my $i (1 .. 10) {
    my $end = $delay->begin;
    Mojo::IOLoop->timer($i => sub {
      say 10 - $i;
      $end->();
    });
  }
  $delay->wait;

  # Sequentialize multiple non-blocking operations
  Mojo::IOLoop->delay(

    # First step (simple timer)
    sub {
      my $delay = shift;
      Mojo::IOLoop->timer(2 => $delay->begin);
      say 'Second step in 2 seconds.';
    },

    # Second step (concurrent timers)
    sub {
      my $delay = shift;
      Mojo::IOLoop->timer(1 => $delay->begin);
      Mojo::IOLoop->timer(3 => $delay->begin);
      say 'Third step in 3 seconds.';
    },

    # Third step (the end)
    sub { say 'And done after 5 seconds total.' }
  )->wait;

=head2 is_running

  my $bool = Mojo::IOLoop->is_running;
  my $bool = $loop->is_running;

Check if event loop is running.

  exit unless Mojo::IOLoop->is_running;

=head2 next_tick

  my $undef = Mojo::IOLoop->next_tick(sub {...});
  my $undef = $loop->next_tick(sub {...});

Execute callback as soon as possible, but not before returning or other
callbacks that have been registered with this method, always returns C<undef>.

  # Perform operation on next reactor tick
  Mojo::IOLoop->next_tick(sub {
    my $loop = shift;
    ...
  });

=head2 one_tick

  Mojo::IOLoop->one_tick;
  $loop->one_tick;

Run event loop until an event occurs.

  # Don't block longer than 0.5 seconds
  my $id = Mojo::IOLoop->timer(0.5 => sub {});
  Mojo::IOLoop->one_tick;
  Mojo::IOLoop->remove($id);

=head2 recurring

  my $id = Mojo::IOLoop->recurring(3 => sub {...});
  my $id = $loop->recurring(0 => sub {...});
  my $id = $loop->recurring(0.25 => sub {...});

Create a new recurring timer, invoking the callback repeatedly after a given
amount of time in seconds.

  # Perform operation every 5 seconds
  Mojo::IOLoop->recurring(5 => sub {
    my $loop = shift;
    ...
  });

=head2 remove

  Mojo::IOLoop->remove($id);
  $loop->remove($id);

Remove anything with an id, connections will be dropped gracefully by allowing
them to finish writing all data in their write buffers.

=head2 reset

  Mojo::IOLoop->reset;
  $loop->reset;

Remove everything and stop the event loop.

=head2 server

  my $id = Mojo::IOLoop->server(port => 3000, sub {...});
  my $id = $loop->server(port => 3000, sub {...});
  my $id = $loop->server({port => 3000} => sub {...});

Accept TCP/IP and UNIX domain socket connections with L<Mojo::IOLoop::Server>
and create stream objects (usually L<Mojo::IOLoop::Stream>, takes the same
arguments as L<Mojo::IOLoop::Server/"listen"> in addition to C<stream_class>.

  # Listen on port 3000 with a custom stream class
  my $class = 'Mojo::IOLoop::Stream::HTTPServer';
  Mojo::IOLoop->server({port => 3000, stream_class => $class} => sub {
    my ($loop, $stream, $id) = @_;
    ...
  });

  # Listen on random port
  my $id = Mojo::IOLoop->server({address => '127.0.0.1'} => sub {
    my ($loop, $stream, $id) = @_;
    ...
  });
  my $port = Mojo::IOLoop->acceptor($id)->port;

=head2 singleton

  my $loop = Mojo::IOLoop->singleton;

The global L<Mojo::IOLoop> singleton, used to access a single shared event loop
object from everywhere inside the process.

  # Many methods also allow you to take shortcuts
  Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;

  # Restart active timer
  my $id = Mojo::IOLoop->timer(3 => sub { say 'Timeout!' });
  Mojo::IOLoop->singleton->reactor->again($id);

  # Turn file descriptor into handle and watch if it becomes readable
  my $handle = IO::Handle->new_from_fd($fd, 'r');
  Mojo::IOLoop->singleton->reactor->io($handle => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Handle is writable' : 'Handle is readable';
  })->watch($handle, 1, 0);

=head2 start

  Mojo::IOLoop->start;
  $loop->start;

Start the event loop, this will block until L</"stop"> is called. Note that
some reactors stop automatically if there are no events being watched anymore.

  # Start event loop only if it is not running already
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 stop

  Mojo::IOLoop->stop;
  $loop->stop;

Stop the event loop, this will not interrupt any existing connections and the
event loop can be restarted by running L</"start"> again.

=head2 stop_gracefully

  Mojo::IOLoop->stop_gracefully;
  $loop->stop_gracefully;

Stop accepting new connections and wait for already accepted connections to be
closed, before stopping the event loop.

=head2 stream

  my $stream = Mojo::IOLoop->stream($id);
  my $stream = $loop->stream($id);
  my $id     = $loop->stream(Mojo::IOLoop::Stream->new);

Get L<Mojo::IOLoop::Stream> object for id or turn object into a connection.

  # Increase inactivity timeout for connection to 300 seconds
  Mojo::IOLoop->stream($id)->timeout(300);

=head2 subprocess

  my $subprocess = Mojo::IOLoop->subprocess(sub {...}, sub {...});
  my $subprocess = $loop->subprocess;
  my $subprocess = $loop->subprocess(sub {...}, sub {...});

Build L<Mojo::IOLoop::Subprocess> object to perform computationally expensive
operations in subprocesses, without blocking the event loop. Callbacks will be
passed along to L<Mojo::IOLoop::Subprocess/"run">.

  # Operation that would block the event loop for 5 seconds
  Mojo::IOLoop->subprocess(
    sub {
      my $subprocess = shift;
      sleep 5;
      return '♥', 'Mojolicious';
    },
    sub {
      my ($subprocess, $err, @results) = @_;
      say "Subprocess error: $err" and return if $err;
      say "I $results[0] $results[1]!";
    }
  );

=head2 timer

  my $id = Mojo::IOLoop->timer(3 => sub {...});
  my $id = $loop->timer(0 => sub {...});
  my $id = $loop->timer(0.25 => sub {...});

Create a new timer, invoking the callback after a given amount of time in
seconds.

  # Perform operation in 5 seconds
  Mojo::IOLoop->timer(5 => sub {
    my $loop = shift;
    ...
  });

=head2 transition

  my $stream =
    Mojo::IOLoop->transition($id => 'Mojo::IOLoop::Stream::HTTPClient');
  my $stream = $loop->transition($id => 'Mojo::IOLoop::Stream::HTTPClient');

Transition stream to a different class.

=head1 DEBUGGING

You can set the C<MOJO_IOLOOP_DEBUG> environment variable to get some advanced
diagnostics information printed to C<STDERR>.

  MOJO_IOLOOP_DEBUG=1

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
