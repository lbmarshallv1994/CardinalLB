package OpenSRF::Transport;
use strict; use warnings;
use base 'OpenSRF';
use Time::HiRes qw/time/;
use OpenSRF::AppSession;
use OpenSRF::Utils::Logger qw(:level);
use OpenSRF::DomainObject::oilsResponse qw/:status/;
use OpenSRF::EX qw/:try/;
use OpenSRF::Transport::SlimJabber::MessageWrapper;

#------------------ 
# --- These must be implemented by all Transport subclasses
# -------------------------------------------

=head2 get_listener

Returns the package name of the package the system will use to 
gather incoming requests

=cut

sub get_listener { shift()->alert_abstract(); }

=head2 get_peer_client

Returns the name of the package responsible for client communication

=cut

sub get_peer_client { shift()->alert_abstract(); } 

=head2 get_msg_envelope

Returns the name of the package responsible for parsing incoming messages

=cut

sub get_msg_envelope { shift()->alert_abstract(); } 

# -------------------------------------------

our $message_envelope;
my $logger = "OpenSRF::Utils::Logger"; 



=head2 message_envelope( [$envelope] );

Sets the message envelope class that will allow us to extract
information from the messages we receive from the low 
level transport

=cut

sub message_envelope {
	my( $class, $envelope ) = @_;
	if( $envelope ) {
		$message_envelope = $envelope;
		$envelope->use;
		if( $@ ) {
			$logger->error( 
					"Error loading message_envelope: $envelope -> $@", ERROR);
		}
	}
	return $message_envelope;
}

=head2 handler( $data )

Creates a new MessageWrapper, extracts the remote_id, session_id, and message body
from the message.  Then, creates or retrieves the AppSession object with the session_id and remote_id. 
Finally, creates the message document from the body of the message and calls
the handler method on the message document.

=cut

sub handler {
	my $start_time = time();
	my( $class, $service, $data ) = @_;

	$logger->transport( "Transport handler() received $data", INTERNAL );

	# pass data to the message envelope 
	my $helper = OpenSRF::Transport::SlimJabber::MessageWrapper->new( $data );

	# Extract message information
	my $remote_id	= $helper->get_remote_id();
	my $sess_id	= $helper->get_sess_id();
	my $body	= $helper->get_body();
	my $type	= $helper->get_msg_type();


	if (defined($type) and $type eq 'error') {
		throw OpenSRF::EX::Session ("$remote_id IS NOT CONNECTED TO THE NETWORK!!!");

	}

	# See if the app_session already exists.  If so, make 
	# sure the sender hasn't changed if we're a server
	my $app_session = OpenSRF::AppSession->find( $sess_id );
	if( $app_session and $app_session->endpoint == $app_session->SERVER() and
			$app_session->remote_id ne $remote_id ) {
		$logger->transport( "Backend Gone or invalid sender", INTERNAL );
		my $res = OpenSRF::DomainObject::oilsBrokenSession->new();
		$res->status( "Backend Gone or invalid sender, Reconnect" );
		$app_session->status( $res );
		return 1;
	} 

	# Retrieve or build the app_session as appropriate (server_build decides which to do)
	$logger->transport( "AppSession is valid or does not exist yet", INTERNAL );
	$app_session = OpenSRF::AppSession->server_build( $sess_id, $remote_id, $service );

	if( ! $app_session ) {
		throw OpenSRF::EX::Session ("Transport::handler(): No AppSession object returned from server_build()");
	}

	# Create a document from the JSON contained within the message 
	my $doc; 
	eval { $doc = JSON->JSON2perl($body); };
	if( $@ ) {

		$logger->transport( "Received bogus JSON: $@", INFO );
		$logger->transport( "Bogus JSON data: \n $body \n", INTERNAL );
		my $res = OpenSRF::DomainObject::oilsXMLParseError->new( status => "JSON Parse Error --- $body\n\n$@" );

		$app_session->status($res);
		#$app_session->kill_me;
		return 1;
	}

	$logger->transport( "Transport::handler() creating \n$body", INTERNAL );

	# We need to disconnect the session if we got a jabber error on the client side.  For
	# server side, we'll just tear down the session and go away.
	if (defined($type) and $type eq 'error') {
		# If we're a server
		if( $app_session->endpoint == $app_session->SERVER() ) {
			$app_session->kill_me;
			return 1;
		} else {
			$app_session->reset;
			$app_session->state( $app_session->DISCONNECTED );
			# below will lead to infinite looping, should return an exception
			#$app_session->push_resend( $app_session->app_request( 
			#		$doc->documentElement->firstChild->threadTrace ) );
			$logger->debug(
				"Got Jabber error on client connection $remote_id, nothing we can do..", ERROR );
			return 1;
		}
	}


	# cycle through and pass each oilsMessage contained in the message
	# up to the message layer for processing.
	for my $msg (@$doc) {

		next unless (	$msg && UNIVERSAL::isa($msg => 'OpenSRF::DomainObject::oilsMessage'));

		if( $app_session->endpoint == $app_session->SERVER() ) {

			try {  

				if( ! $msg->handler( $app_session ) ) { return 0; }

				$logger->debug("Successfully handled message", DEBUG);

			} catch Error with {

				my $e = shift;
				my $res = OpenSRF::DomainObject::oilsServerError->new();
				$res->status( $res->status . "\n$e");
				$app_session->status($res) if $res;
				$app_session->kill_me;
				return 0;

			};

		} else { 

			if( ! $msg->handler( $app_session ) ) { return 0; } 
			$logger->debug("Successfully handled message", DEBUG);

		}

	}

	$logger->debug(sprintf("Message processing duration: %.3fs",(time() - $start_time)), DEBUG);

	return $app_session;
}

1;
