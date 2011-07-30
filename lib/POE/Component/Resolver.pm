package POE::Component::Resolver;

use warnings;
use strict;

use POE qw(Wheel::Run Filter::Reference);
use Carp qw(croak);
use Time::HiRes qw(time);
use Socket qw(unpack_sockaddr_in AF_INET AF_INET6);
use Socket::GetAddrInfo qw(:newapi getnameinfo NI_NUMERICHOST NI_NUMERICSERV);

use POE::Component::Resolver::Sidecar;

use Exporter;
use base 'Exporter';
our (@EXPORT_OK) = qw(AF_INET AF_INET6);

# Plain Perl constructor.

sub new {
	my ($class, @args) = @_;

	croak "new() requires an even number of parameters" if @args % 2;
	my %args = @args;

	my $max_resolvers   = delete($args{max_resolvers}) || 8;
	my $idle_timeout    = delete($args{idle_timeout})  || 15;
	my $sidecar_program = delete($args{sidecar_program});

	my $af_order = delete($args{af_order});
	if (defined $af_order and @$af_order) {
		if (ref($af_order) eq "") {
			$af_order = [ $af_order ];
		}
		elsif (ref($af_order) ne "ARRAY") {
			croak "af_order must be a scalar or an array reference";
		}

		my @illegal_afs = grep { ($_ ne AF_INET) && ($_ ne AF_INET6) } @$af_order;
		croak "af_order may only contain AF_INET and/or AF_INET6" if @illegal_afs;
	}
	else {
		# Default to IPv4 preference for backward compatibility.
		# TODO - Check an environment variable to override.
		$af_order = [ AF_INET, AF_INET6 ];
	}

	my @error = sort keys %args;
	croak "unknown new() parameter(s): @error" if @error;

	unless (defined $sidecar_program and length $sidecar_program) {
		if ($^O eq "MSWin32") {
			$sidecar_program = \&POE::Component::Resolver::Sidecar::main;
		}
		else {
			$sidecar_program = [
				$^X,
				(map { "-I$_" } @INC),
				'-MPOE::Component::Resolver::Sidecar',
				'-e', 'POE::Component::Resolver::Sidecar->main()'
			];
		}
	}

	my $self = bless { }, $class;

	POE::Session->create(
		inline_states => {
			_start           => \&_poe_start,
			_stop            => sub { undef },  # for ASSERT_DEFAULT
			_parent          => sub { undef },  # for ASSERT_DEFAULT
			_child           => sub { undef },  # for ASSERT_DEFAULT
			request          => \&_poe_request,
			shutdown         => \&_poe_shutdown,
			sidecar_closed   => \&_poe_sidecar_closed,
			sidecar_error    => \&_poe_sidecar_error,
			sidecar_response => \&_poe_sidecar_response,
			sidecar_signal   => \&_poe_sidecar_signal,
			sidecar_eject    => \&_poe_sidecar_eject,
			sidecar_attach   => \&_poe_sidecar_attach,
		},
		heap => {
			af_order        => $af_order,
			alias           => "$self",
			idle_timeout    => $idle_timeout,
			last_request_id => 0,
			max_resolvers   => $max_resolvers,
			requests        => { },
			sidecar_ring    => [ ],
			sidecar_program => $sidecar_program,
		}
	);

	return $self;
}

sub DESTROY {
	my $self = shift;

	# Can't resolve the session: it must already be gone.
	return unless $poe_kernel->alias_resolve("$self");

	$poe_kernel->call("$self", "shutdown");
}

sub shutdown {
	my $self = shift;

	# Can't resolve the session: it must already be gone.
	return unless $poe_kernel->alias_resolve("$self");

	$poe_kernel->call("$self", "shutdown");
}

# Internal POE event handler to release all resources owned by the
# hidden POE::Session and then shut it down.  It's an event handler so
# that this code can run "within" the POE::Session.

sub _poe_shutdown {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$heap->{shutdown} = 1;

	$kernel->alias_remove($heap->{alias});

	_poe_wipe_sidecars($heap);

	foreach my $request (values %{$heap->{requests}}) {
		$kernel->post(
			$request->{sender},
			$request->{event},
			'component shut down',
			[ ],
			{ map { $_ => $request->{$_} } qw(host service misc) },
		);

		$kernel->refcount_decrement($request->{sender}, __PACKAGE__);
	}

	$heap->{requests} = {};
}

# POE event handler to accept a request from some other session.  The
# public Perl resolve() method forwards into this.  This runs "within"
# the session so the resources it creates are properly owned.

sub _poe_request {
	my ($kernel, $heap, $host, $service, $hints, $event, $misc) = @_[
		KERNEL, HEAP, ARG0..ARG4
	];

	return if $heap->{shutdown};

	my $request_id = ++$heap->{last_request_id};
	my $sender_id  = $_[SENDER]->ID();

	$kernel->refcount_increment($sender_id, __PACKAGE__);

	_poe_setup_sidecar_ring($kernel, $heap);

	my $next_sidecar = pop @{$heap->{sidecar_ring}};
	unshift @{$heap->{sidecar_ring}}, $next_sidecar;

	$next_sidecar->put( [ $request_id, $host, $service, $hints ] );

	$heap->{requests}{$request_id} = {
		begin       => time(),
		host        => $host,
		service     => $service,
		hints       => $hints,
		sender      => $sender_id,
		event       => $event,
		misc        => $misc,
		sidecar_id  => $next_sidecar->ID(),
	};

	# No ejecting until we're done.
	$kernel->delay(sidecar_eject => undef);

	return 1;
}

# POE _start handler.  Initialize the session and start sidecar
# processes, which are owned and managed by that session.

sub _poe_start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->alias_set($heap->{alias});

	_poe_setup_sidecar_ring($kernel, $heap);

	undef;
}

# Internal helper sub.  Make sure the apprpriate number of sidecar
# resolvers are running at any given time.

sub _poe_setup_sidecar_ring {
	my ($kernel, $heap) = @_;

	return if $heap->{shutdown};

	while (scalar(keys %{$heap->{sidecar}}) < $heap->{max_resolvers}) {
		my $sidecar = POE::Wheel::Run->new(
			StdioFilter  => POE::Filter::Reference->new(),
			StdoutEvent  => 'sidecar_response',
			StderrEvent  => 'sidecar_error',
			CloseEvent   => 'sidecar_closed',
			Program      => $heap->{sidecar_program},
		);

		$heap->{sidecar}{$sidecar->PID}   = $sidecar;
		$heap->{sidecar_id}{$sidecar->ID} = $sidecar;
		push @{$heap->{sidecar_ring}}, $sidecar;

		$kernel->sig_child($sidecar->PID(), "sidecar_signal");
	}
}

# Internal helper sub to replay pending requests when their associated
# sidecars are destroyed.

sub _poe_replay_pending {
	my ($kernel, $heap) = @_;

	while (my ($request_id, $request) = each %{$heap->{requests}}) {

		# This request is riding in an existing sidecar.
		# No need to replay it.
		next if exists $heap->{sidecar_id}{$request->{sidecar_id}};

		# Give the request to a new sidecar.
		my $next_sidecar = pop @{$heap->{sidecar_ring}};
		unshift @{$heap->{sidecar_ring}}, $next_sidecar;

		$request->{sidecar_id} = $next_sidecar->ID();

		$next_sidecar->put(
			[
				$request_id, $request->{host}, $request->{service}, $request->{hints}
			]
		);
	}
}

# Internal event handler to briefly defer replaying requests until any
# responses in the queue have had time to be delivered.  This prevents
# us from replaying requests that may already have answers.

sub _poe_sidecar_attach {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	# Nothing to do if we don't have requests.
	return unless scalar keys %{$heap->{reuqests}};

	# Requests exist.
	_poe_setup_sidecar_ring($kernel, $heap);
	_poe_replay_pending($kernel, $heap);
}

# Plain public Perl method.  Begin resolving something.

sub resolve {
	my ($self, @args) = @_;

	croak "resolve() requires an even number of parameters" if @args % 2;
	my %args = @args;

	my $host = delete $args{host};
	croak "resolve() requires a host" unless defined $host and length $host;

	my $service = delete $args{service};
	croak "resolve() requires a service" unless (
		defined $service and length $service
	);

	my $misc = delete $args{misc};
	$misc = "" unless defined $misc;

	my $hints = delete $args{hints};
	$hints ||= { };

	my $event = delete $args{event};
	$event = "resolver_response" unless defined $event and length $event;

	my @error = sort keys %args;
	croak "unknown resolve() parameter(s): @error" if @error;

	croak "resolve() on shutdown resolver" unless (
		$poe_kernel->call(
			"$self", "request", $host, $service, $hints, $event, $misc
		)
	);
}

# A sidecar process has produced an error or warning.  Pass it
# through to the parent process' console.

sub _poe_sidecar_error {
	warn __PACKAGE__, " error in getaddrinfo subprocess: $_[ARG0]\n";
}

# A sidecar process has closed its standard output.  We will receive
# no more responses from it.  Clean up the sidecar's resources, and
# start new ones if necessary.

sub _poe_sidecar_closed {
	my ($kernel, $heap, $wheel_id) = @_[KERNEL, HEAP, ARG0];

	# Don't bother checking for pending requests if we've shut down.
	return if $heap->{shutdown};

	my $sidecar = delete $heap->{sidecar_id}{$wheel_id};
	if (defined $sidecar) {
		$sidecar->kill(9);
		delete $heap->{sidecar}{$sidecar->PID()};
	}

	# Remove the sidecar from the rotation.
	my $i = @{$heap->{sidecar_ring}};
	while ($i--) {
		next unless $heap->{sidecar_ring}[$i]->ID() == $wheel_id;
		splice(@{$heap->{sidecar_ring}}, 1, 1);
		last;
	}

	_poe_setup_sidecar_ring($kernel, $heap);
	_poe_replay_pending($kernel, $heap) if scalar keys %{$heap->{requests}};
}

# A sidecar has produced a response.  Pass it back to the original
# caller of resolve().  If we've run out of requests, briefly defer a
# partial shutdown.  We don't need all those sidecar processes if we
# might be done.

sub _poe_sidecar_response {
	my ($kernel, $heap, $response_rec) = @_[KERNEL, HEAP, ARG0];
	my ($request_id, $error, $addresses) = @$response_rec;

	my $request_rec = delete $heap->{requests}{$request_id};
	return unless defined $request_rec;

	if (defined $heap->{af_order}) {
		my @filtered_addresses;
		foreach my $af_filter (@{$heap->{af_order}}) {
			push @filtered_addresses, grep { $_->{family} == $af_filter } @$addresses;
		}
		$addresses = \@filtered_addresses;
	}

	$kernel->post(
		$request_rec->{sender}, $request_rec->{event},
		$error, $addresses,
		{ map { $_ => $request_rec->{$_} } qw(host service misc) },
	);

	$kernel->refcount_decrement($request_rec->{sender}, __PACKAGE__);

	# No more requests?  Consder detaching sidecar.
	$kernel->delay(sidecar_eject => $heap->{idle_timeout}) unless (
		scalar keys %{$heap->{requests}}
	);
}

# A sidecar process has exited.  Clean up its resources, and attach a
# replacement sidecar if there are requests.

sub _poe_sidecar_signal {
	my ($heap, $pid) = @_[HEAP, ARG1];

	return unless exists $heap->{sidecar}{$pid};
	my $sidecar = delete $heap->{sidecar}{$pid};
	my $sidecar_id = $sidecar->ID();
	delete $heap->{sidecar_id}{$sidecar_id};

	# Remove the sidecar from the rotation.
	my $i = @{$heap->{sidecar_ring}};
	while ($i--) {
		next unless $heap->{sidecar_ring}[$i]->ID() == $sidecar_id;
		splice(@{$heap->{sidecar_ring}}, 1, 1);
		last;
	}

	$_[KERNEL]->yield("sidecar_attach") if scalar keys %{$heap->{requests}};

	undef;
}

# Event handler to defer wiping out all sidecars.  This allows for
# lazy cleanup, which may eliminate thrashing in some situations.

sub _poe_sidecar_eject {
	my ($kernel, $heap) = @_[KERNEL, HEAP];
	_poe_wipe_sidecars($heap) unless scalar keys %{$heap->{requests}};
}

# Internal helper sub to synchronously wipe out all sidecars.

sub _poe_wipe_sidecars {
	my $heap = shift;

	return unless @{$heap->{sidecar_ring}};

	foreach my $sidecar (@{$heap->{sidecar_ring}}) {
		$sidecar->kill(-9);
	}

	$heap->{sidecar}      = {};
	$heap->{sidecar_id}   = {};
	$heap->{sidecar_ring} = [];
}

sub unpack_addr {
	my ($self, $address_rec) = @_;

	my ($error, $address, $port) = (
		(getnameinfo $address_rec->{addr}, NI_NUMERICHOST | NI_NUMERICSERV)[0,1]
	);

	return if $error;
	return($address, $port) if wantarray();
	return $address;
}

1;

__END__

=head1 NAME

POE::Component::Resolver - A non-blocking getaddrinfo() resolver

=head1 SYNOPSIS

	#!/usr/bin/perl

	use warnings;
	use strict;

	use POE;
	use POE::Component::Resolver qw(AF_INET AF_INET6);

	my $r = POE::Component::Resolver->new(
		max_resolvers => 8,
		idle_timeout  => 5,
		af_order      => [ AF_INET6, AF_INET ],
		# sidecar_program => $path_to_program,
	);

	my @hosts = qw( ipv6-test.com );
	my $tcp   = getprotobyname("tcp");

	POE::Session->create(
		inline_states => {
			_start => sub {
				foreach my $host (@hosts) {
					$r->resolve(
						host    => $host,
						service => "http",
						event   => "got_response",
						hints   => { protocol => $tcp },
					) or die $!;
				}
			},

			_stop => sub { print "client session stopped\n" },

			got_response => sub {
				my ($error, $addresses, $request) = @_[ARG0..ARG2];
				use YAML; print YAML::Dump(
					{
						error => $error,
						addr => $addresses,
						req => $request,
					}
				);
			},
		}
	);

	POE::Kernel->run();

=head1 DESCRIPTION

POE::Component::Resolver performs Socket::GetAddrInfo::getaddrinfo()
calls in subprocesses where they're permitted to block as long as
necessary.

By default it will run eight subprocesses and prefer address families
in whatever order Socket::GetAddrInfo returns them.  These defaults
can be overridden with constructor parameters.

=head2 PUBLIC METHODS

=head3 new

Create a new resolver.  Returns an object that must be held and used
to make requests.  See the synopsis.

Accepts up to four optional named parameters.

"af_order" may contain an arrayref with the address families to
permit, in the order in which they're preferred.  Without "af_order",
the component will return addresses in the order in which
Socket::GetAddrInfo provides them.

	# Prefer IPv6 addresses, but also return IPv4 ones.
	my $r1 = POE::Component::Resolver->new(
		af_order => [ AF_INET6, AF_INET ]
	);

	# Only return AF_INET6 addresses.
	my $r2 = POE::Component::Resolver->new(
		af_order => [ AF_INET6 ]
	);

"idle_timeout" determines how long to keep idle resolver subprocesses
before cleaning them up, in seconds.  It defaults to 15.0 seconds.

"max_resolvers" controls the component's parallelism by defining the
maximum number of sidecar processes to manage.  It defaults to 8, but
fewer or more processes can be configured depending on the resources
you have available and the amount of parallelism you require.

	# One at a time, but without the pesky blocking.
	my $r3 = POE::Component::Resolver->new( max_resolvers => 1 );

"sidecar_program" contains the disk location of a program that will
perform blocking lookups on standard input and print the results on
standard output.  The sidecar program is needed only in special
environments where the bundling and execution of extra utilities is
tricky.  PAR is one such environment.

The sidecar program needs to contain at least two statements:

	use POE::Component::Resolver::Sidecar;
	POE::Component::Resover::Sidecar->main();

=head3 resolve

resolve() begins a new request to resolve a domain.  The request will
be enqueued in the component until a sidecar process can service it.
Resolve requires two parameters and accepts some additional optional
ones.

"host" and "service" are required and contain the host (name or
Internet address) and service (name or numeric port) that will be
passed verbatim to getaddrinfo().  See L<Socket::GetAddrInfo> for
details.

"event" is optional; it contains the name of the event that will
contain the resolver response.  If omitted, it will default to
"resolver_response"; you may want to specify a shorter event name.

"hints" is optional.  If specified, it must contain a hashref of hints
exactly as getaddrinfo() expects them.  See L<Socket::GetAddrInfo> for
details.

"misc" is optional continuation data that will be passed back in the
response.  It may contain any type of data the application requires.

=head3 shutdown

Shut down the resolver.  POE::Component::Resolver retains resources
including child processes for up to "idle_timeout" seconds.  This may
keep programs running up to "idle_timeout" seconds longer than they
should.

POE::Component::Resolver will release its resources (including child
processes) when its shutdown() method is called.

=head3 unpack_addr

In scalar context, unpack_addr($response_addr_hashref) returns the
addr element of $response_addr_hashref in a numeric form appropriate
for the address family of the address.

	sub handle_resolver_response {
		my ($error, $addresses, $request) = @_[ARG0..ARG2];

		foreach my $a (@$addresses) {
			my $numeric_addr = $resolver->unpack_addr($a);
			print "$request->{host} = $numeric_addr\n";
		}
	}

In list context, it returns the numeric port and address.

	sub handle_resolver_response {
		my ($error, $addresses, $request) = @_[ARG0..ARG2];

		foreach my $a (@$addresses) {
			my ($$numeric_addr, $port) = $resolver->unpack_addr($a);
			print "$request->{host} = $numeric_addr\n";
		}
	}

unpack_addr() is a convenience wrapper around getnameinfo() from
Socket::GetAddrInfo.  You're certainly welcome to use the discrete
function instead.

unpack_addr() returns bleak emptiness on failure, regardless of
context.  You can check for undef return.

=head2 PUBLIC EVENTS

=head3 resolver_response

The resolver response event includes three parameters.

$_[ARG0] and $_[ARG1] contain the retrn values from
Socket::GetAddrInfo's getaddrinfo() call.  These are an error message
(if the call failed), and an arrayref of address structures if the
call succeeded.

The component provides its own error message, 'component shut down'.
This response is given for every pending request at the time the user
shuts down the component.

$_[ARG2] contains a hashref of information provided to the resolve()
method.  Specifically, the values of resolve()'s "host", "service" and
"misc" parameters.

=head1 COMPATIBILITY ISSUES

=head2 Microsoft Windows

This module requires "Microsoft TCP/IP version 6" to be installed.
Steps for Windows XP Pro (the steps for your particular version of
Windows may be subtly or drastically different):

=over

=item * Open your Control Panel

=item * Open your Network Connections

=item * Select your network connection from the available one(s)

=item * In the Local Area Connection Status dialog, click the Properties button

=item * If "Microsoft TCP/IP version 6" is listed as an item being used, you are done.

=item * Otherwise click Install...

=item * Choose to add a Protocol

=item * And install "Microsoft TCP/IP version 6" from the list of network protocols.

=back

=head1 BUGS

There is no timeout on requests.

There is no way to cancel a pending request.

=head1 TROUBLESHOOTING

=head2 programs linger for several seconds before exiting

Programs should shutdown() their POE::Component::Resolver objects when
they are through needing asynchronous DNS resolution.  Programs should
additionally destroy their resolvers if they intend to run awhile and
want to reuse the memory they consume.

In some cases, it may be necessary to shutdown components that perform
asynchronous DNS using POE::Component::Resolver... such as
POE::Component::IRC, POE::Component::Client::Keepalive and
POE::Component::Client::HTTP.

By default, the resolver subprocesses hang around for idle_timeout,
which defaults to 15.0 seconds.  Destroying the Resolver object will
clean up the process pool.  Assuming only that is keeping the event
loop active, the program will then exit cleanly.

Alternatively, reduce idle_timeout to a more manageable number, such
as 5.0 seconds.

Otherwise something else may also be keeping the event loop active.

=head1 LICENSE

Except where otherwise noted, this distribution is Copyright 2011 by
Rocco Caputo.  All rights reserved.  This distribution is free
software; you may redistribute it and/or modify it under the same
terms as Perl itself.

=cut
